// Command main is the Go stack's data-access checker. It decides the
// decidable halves of R-361 and R-362 from the syntax of each file alone,
// using only the standard library (go/parser, go/ast, go/token), because a
// golangci-lint custom linter needs a plugin build. push-golangci-gate.sh
// builds it once per gate run and scopes its findings to the lines the
// outgoing diff adds.
//
// Usage: go run main.go -- <file>...  (or a built binary: checker <file>...)
//
// The -- matters under go run: without it, go run takes every leading .go
// argument as a source file of the program instead of as an argument to it.
// A leading -- is skipped.
//
// It prints a JSON array, one object per finding:
//
//	{"file": "<path as given>", "line": 12, "rule": "R-361", "message": "..."}
//
// and prints [] when there are none. It exits 0 with or without findings and
// exits 2 on bad usage. A file that does not parse is skipped.
//
// A data-access call is one of:
//   - a method call named Query, QueryRow, Exec, QueryContext,
//     QueryRowContext, ExecContext, or CopyFrom with at least one argument, on
//     any receiver (pgx pool, conn, or tx, and database/sql); a zero-argument
//     call such as url.URL.Query() is not one;
//   - any call through a package imported from a path with a `repository` or
//     `repositories` element;
//   - a method call on a receiver whose name ends in Repository, Repo,
//     repository, or repo (s.tripRepository.GetTrip, repo.Get).
//
// Reading the results of a pgx batch (a receiver assigned from SendBatch) is
// not data access: batching is the fix for the N+1, not an instance of it.
//
// R-361 (the N+1) reports a data-access call evaluated once per iteration: in
// the body of any for statement (three-clause, condition-only, infinite, or
// range), in the condition or post clause of a three-clause for, and inside a
// function literal that the loop body invokes (go func(){...}(), a literal
// called in place, or a literal passed as an argument, such as g.Go(func...)).
// Not reported: the range expression and the init clause, which run once, and
// a function literal that is only assigned or returned. A function declared
// elsewhere and called in the loop is not followed; the query-budget test in
// CLAUDE-DATABASE.md covers that case.
//
// R-362 reports, inside a function literal passed to BeginFunc, BeginTxFunc,
// WithTx, WithTransaction, InTx, or RunInTx whose parameters include a
// transaction (pgx.Tx, *sql.Tx, or any type whose name ends in Tx):
//   - a data-access call that neither runs on the transaction nor receives it
//     (the transaction's identifier appears nowhere in the call's receiver or
//     arguments); with a blank (_) transaction parameter every data-access
//     call reports;
//   - network I/O: http.Get, http.Head, http.Post, http.PostForm, any call on
//     http.DefaultClient, a .Do call on a receiver named like a client, and any
//     call into a package imported from a path with a `clients` element.
//
// A literal whose parameters carry no transaction (a helper that passes the
// transaction through context.Context) is not checked, since which connection
// each call uses is not visible in the syntax.
//
// What it does NOT decide: a query hidden behind a helper declared elsewhere,
// whether a group of writes needed a transaction at all (intent, left to the
// judge), and network I/O through a client that is not named as one.
//
// A finding is suppressed by `// data-access-allow: <reason>` on its line or
// the line directly above; a comment with no reason does not suppress.
// _test.go files and paths with a testdata, scripts, migrations, or cmd/tools
// segment are exempt.
package main

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const (
	ruleQueryInLoop    = "R-361"
	ruleTransactionUse = "R-362"
	exitUsage          = 2
)

var (
	queryMethods = map[string]bool{
		"Query": true, "QueryRow": true, "Exec": true,
		"QueryContext": true, "QueryRowContext": true, "ExecContext": true,
		"CopyFrom": true,
	}
	transactionHelpers = map[string]bool{
		"BeginFunc": true, "BeginTxFunc": true, "WithTx": true,
		"WithTransaction": true, "InTx": true, "RunInTx": true,
	}
	httpPackageFunctions = map[string]bool{"Get": true, "Head": true, "Post": true, "PostForm": true}
	repositorySuffixes   = []string{"Repository", "Repo", "repository", "repo"}
	exemptSegments       = map[string]bool{"testdata": true, "scripts": true, "migrations": true}
	allowComment         = regexp.MustCompile(`^//\s*data-access-allow:\s*\S`)
	clientReceiver       = regexp.MustCompile(`(?i)client$`)
)

// finding is one reported defect, in the shape the push gate reads.
type finding struct {
	File    string `json:"file"`
	Line    int    `json:"line"`
	Rule    string `json:"rule"`
	Message string `json:"message"`
}

// fileChecker holds what one file's checks need: its imports, the receivers
// that hold batch results, and the lines a suppression comment covers.
type fileChecker struct {
	path              string
	fset              *token.FileSet
	repositoryImports map[string]bool
	clientImports     map[string]bool
	httpImport        string
	batchResults      map[string]bool
	allowedLines      map[int]bool
	findings          []finding
}

func main() {
	paths := os.Args[1:]
	if len(paths) > 0 && paths[0] == "--" {
		paths = paths[1:]
	}
	if len(paths) == 0 {
		fmt.Fprintln(os.Stderr, "usage: go run main.go -- <file>...")
		os.Exit(exitUsage)
	}
	findings := []finding{}
	for _, path := range paths {
		findings = append(findings, checkFile(path)...)
	}
	sort.SliceStable(findings, func(i, j int) bool {
		if findings[i].File != findings[j].File {
			return findings[i].File < findings[j].File
		}
		if findings[i].Line != findings[j].Line {
			return findings[i].Line < findings[j].Line
		}
		return findings[i].Rule < findings[j].Rule
	})
	out, err := json.Marshal(findings)
	if err != nil {
		fmt.Fprintln(os.Stderr, "data-access checker: cannot encode findings:", err)
		os.Exit(1)
	}
	fmt.Println(string(out))
}

// checkFile parses one file and returns its unsuppressed findings; an exempt
// or unparsable file yields none.
func checkFile(path string) []finding {
	if isExempt(path) {
		return nil
	}
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, path, nil, parser.ParseComments)
	if err != nil {
		return nil
	}
	checker := &fileChecker{
		path:              path,
		fset:              fset,
		repositoryImports: map[string]bool{},
		clientImports:     map[string]bool{},
		batchResults:      map[string]bool{},
		allowedLines:      map[int]bool{},
	}
	checker.collectImports(file)
	checker.collectBatchResults(file)
	checker.collectAllowComments(file)
	checker.visitLoops(file, false)
	checker.checkTransactions(file)
	return checker.findings
}

// isExempt reports whether the path is a test file or sits under a directory
// the rules exempt (fixtures, scripts, migrations, one-off tools).
func isExempt(path string) bool {
	if strings.HasSuffix(path, "_test.go") {
		return true
	}
	segments := strings.Split(filepath.ToSlash(path), "/")
	for i, segment := range segments {
		if exemptSegments[segment] {
			return true
		}
		if segment == "cmd" && i+1 < len(segments) && segments[i+1] == "tools" {
			return true
		}
	}
	return false
}

// collectImports records the local names of repository, client, and net/http
// imports.
func (c *fileChecker) collectImports(file *ast.File) {
	for _, spec := range file.Imports {
		importPath, err := strconv.Unquote(spec.Path.Value)
		if err != nil {
			continue
		}
		local := importPath[strings.LastIndex(importPath, "/")+1:]
		if spec.Name != nil {
			local = spec.Name.Name
		}
		if local == "_" || local == "." {
			continue
		}
		if importPath == "net/http" {
			c.httpImport = local
			continue
		}
		for _, element := range strings.Split(importPath, "/") {
			switch element {
			case "repository", "repositories":
				c.repositoryImports[local] = true
			case "clients":
				c.clientImports[local] = true
			}
		}
	}
}

// collectBatchResults records every identifier assigned from a SendBatch
// call, so reading a batch's results is not mistaken for a query.
func (c *fileChecker) collectBatchResults(file *ast.File) {
	ast.Inspect(file, func(node ast.Node) bool {
		assign, ok := node.(*ast.AssignStmt)
		if !ok || len(assign.Rhs) != 1 {
			return true
		}
		call, ok := assign.Rhs[0].(*ast.CallExpr)
		if !ok || selectorName(call.Fun) != "SendBatch" {
			return true
		}
		for _, lhs := range assign.Lhs {
			if ident, isIdent := lhs.(*ast.Ident); isIdent {
				c.batchResults[ident.Name] = true
			}
		}
		return true
	})
}

// collectAllowComments records the lines covered by a suppression comment
// that states a reason: its own line and the line below it.
func (c *fileChecker) collectAllowComments(file *ast.File) {
	for _, group := range file.Comments {
		for _, comment := range group.List {
			if allowComment.MatchString(comment.Text) {
				line := c.fset.Position(comment.Slash).Line
				c.allowedLines[line] = true
				c.allowedLines[line+1] = true
			}
		}
	}
}

// report appends a finding unless a suppression comment covers its line.
func (c *fileChecker) report(pos token.Pos, rule, message string) {
	line := c.fset.Position(pos).Line
	if c.allowedLines[line] {
		return
	}
	c.findings = append(c.findings, finding{File: c.path, Line: line, Rule: rule, Message: message})
}

// visitLoops walks node, tracking whether the code is evaluated once per
// iteration of an enclosing for statement, and reports R-361 findings.
func (c *fileChecker) visitLoops(node ast.Node, inLoop bool) {
	if node == nil {
		return
	}
	ast.Inspect(node, func(current ast.Node) bool {
		switch typed := current.(type) {
		case *ast.ForStmt:
			c.visitLoops(typed.Init, inLoop)
			c.visitLoops(typed.Cond, true)
			c.visitLoops(typed.Post, true)
			c.visitLoops(typed.Body, true)
			return false
		case *ast.RangeStmt:
			c.visitLoops(typed.X, inLoop)
			c.visitLoops(typed.Body, true)
			return false
		case *ast.FuncLit:
			// A literal reached here is assigned, returned, or stored, not
			// invoked by the loop, so its body does not repeat per iteration.
			c.visitLoops(typed.Body, false)
			return false
		case *ast.CallExpr:
			c.visitCall(typed, inLoop)
			return false
		}
		return true
	})
}

// visitCall reports the call itself when it is data access inside a loop,
// then walks its callee and arguments, carrying the loop state into a
// function literal that the call invokes or receives.
func (c *fileChecker) visitCall(call *ast.CallExpr, inLoop bool) {
	if inLoop {
		if label, ok := c.describeDataAccess(call); ok {
			c.report(callPos(call), ruleQueryInLoop, fmt.Sprintf(
				"%s runs once per loop iteration (N+1); load or write the whole set in one query (= ANY($1), a JOIN, unnest, or a pgx.Batch) or use the repository's plural method.", label))
		}
	}
	if literal, ok := unparen(call.Fun).(*ast.FuncLit); ok {
		c.visitLoops(literal.Body, inLoop)
	} else {
		c.visitLoops(call.Fun, inLoop)
	}
	for _, argument := range call.Args {
		if literal, ok := unparen(argument).(*ast.FuncLit); ok {
			c.visitLoops(literal.Body, inLoop)
			continue
		}
		c.visitLoops(argument, inLoop)
	}
}

// describeDataAccess returns a short label for the callee when the call
// reaches the database.
func (c *fileChecker) describeDataAccess(call *ast.CallExpr) (string, bool) {
	selector, ok := unparen(call.Fun).(*ast.SelectorExpr)
	if !ok {
		return "", false
	}
	receiver := receiverName(selector.X)
	label := exprLabel(selector.X) + "." + selector.Sel.Name
	if c.batchResults[receiver] {
		return "", false
	}
	if queryMethods[selector.Sel.Name] && len(call.Args) > 0 && receiver != "URL" {
		return label, true
	}
	if ident, isIdent := selector.X.(*ast.Ident); isIdent && c.repositoryImports[ident.Name] {
		return label, true
	}
	for _, suffix := range repositorySuffixes {
		if strings.HasSuffix(receiver, suffix) {
			return label, true
		}
	}
	return "", false
}

// checkTransactions finds each transaction callback in the file and checks
// its body for R-362.
func (c *fileChecker) checkTransactions(file *ast.File) {
	ast.Inspect(file, func(node ast.Node) bool {
		call, ok := node.(*ast.CallExpr)
		if !ok || !transactionHelpers[calleeName(call.Fun)] {
			return true
		}
		for _, argument := range call.Args {
			literal, isLiteral := unparen(argument).(*ast.FuncLit)
			if !isLiteral {
				continue
			}
			if txName, found := transactionParameter(literal); found {
				c.checkTransactionBody(literal.Body, txName, calleeName(call.Fun))
			}
		}
		return true
	})
}

// checkTransactionBody reports data access off the transaction and network
// I/O inside one transaction callback. A nested transaction callback is left
// to its own check, since its statements belong to its own transaction.
func (c *fileChecker) checkTransactionBody(body *ast.BlockStmt, txName, helper string) {
	ast.Inspect(body, func(node ast.Node) bool {
		call, ok := node.(*ast.CallExpr)
		if !ok {
			return true
		}
		if transactionHelpers[calleeName(call.Fun)] {
			for _, argument := range call.Args {
				if literal, isLiteral := unparen(argument).(*ast.FuncLit); isLiteral {
					if _, found := transactionParameter(literal); found {
						return false
					}
				}
			}
		}
		if label, isDataAccess := c.describeDataAccess(call); isDataAccess && (txName == "_" || !mentionsIdent(call, txName)) {
			c.report(callPos(call), ruleTransactionUse, fmt.Sprintf(
				"%s inside the %s callback runs outside the transaction; %s so it commits and rolls back with the other statements.", label, helper, transactionFix(txName)))
		}
		if label, isNetwork := c.describeNetworkCall(call); isNetwork {
			c.report(callPos(call), ruleTransactionUse, fmt.Sprintf(
				"%s inside the %s callback holds the transaction open across a network round trip; make the call before the transaction opens or after it commits, or write an outbox row.", label, helper))
		}
		return true
	})
}

// describeNetworkCall returns a label when the call performs outbound network
// I/O: net/http helpers, http.DefaultClient, .Do on a client, or a clients/
// package.
func (c *fileChecker) describeNetworkCall(call *ast.CallExpr) (string, bool) {
	selector, ok := unparen(call.Fun).(*ast.SelectorExpr)
	if !ok {
		return "", false
	}
	label := exprLabel(selector.X) + "." + selector.Sel.Name
	if ident, isIdent := selector.X.(*ast.Ident); isIdent {
		if c.httpImport != "" && ident.Name == c.httpImport && httpPackageFunctions[selector.Sel.Name] {
			return label, true
		}
		if c.clientImports[ident.Name] {
			return label, true
		}
	}
	if inner, isSelector := selector.X.(*ast.SelectorExpr); isSelector && c.httpImport != "" {
		if pkg, isIdent := inner.X.(*ast.Ident); isIdent && pkg.Name == c.httpImport && inner.Sel.Name == "DefaultClient" {
			return label, true
		}
	}
	if selector.Sel.Name == "Do" && clientReceiver.MatchString(receiverName(selector.X)) {
		return label, true
	}
	return "", false
}

// transactionParameter returns the name of the literal's transaction
// parameter (pgx.Tx, *sql.Tx, or a type whose name ends in Tx).
func transactionParameter(literal *ast.FuncLit) (string, bool) {
	if literal.Type.Params == nil {
		return "", false
	}
	for _, field := range literal.Type.Params.List {
		if !strings.HasSuffix(typeName(field.Type), "Tx") {
			continue
		}
		if len(field.Names) == 0 {
			return "_", true
		}
		return field.Names[0].Name, true
	}
	return "", false
}

// typeName returns the final identifier of a type expression, through
// pointers and package qualifiers.
func typeName(expr ast.Expr) string {
	switch typed := expr.(type) {
	case *ast.StarExpr:
		return typeName(typed.X)
	case *ast.SelectorExpr:
		return typed.Sel.Name
	case *ast.Ident:
		return typed.Name
	}
	return ""
}

// mentionsIdent reports whether name appears in the call's callee or
// arguments, outside any nested function literal.
func mentionsIdent(call *ast.CallExpr, name string) bool {
	found := false
	visit := func(node ast.Node) bool {
		if found {
			return false
		}
		switch typed := node.(type) {
		case *ast.FuncLit:
			return false
		case *ast.Ident:
			if typed.Name == name {
				found = true
			}
		}
		return true
	}
	ast.Inspect(call.Fun, visit)
	for _, argument := range call.Args {
		ast.Inspect(argument, visit)
	}
	return found
}

// calleeName returns the called function's name: the identifier or the
// selector's final name.
func calleeName(fun ast.Expr) string {
	switch typed := unparen(fun).(type) {
	case *ast.Ident:
		return typed.Name
	case *ast.SelectorExpr:
		return typed.Sel.Name
	}
	return ""
}

// selectorName returns the selector's final name, or "" for other callees.
func selectorName(fun ast.Expr) string {
	if selector, ok := unparen(fun).(*ast.SelectorExpr); ok {
		return selector.Sel.Name
	}
	return ""
}

// receiverName returns the last identifier of a receiver expression
// (s.tripRepository gives tripRepository), or "" when there is none.
func receiverName(expr ast.Expr) string {
	switch typed := unparen(expr).(type) {
	case *ast.Ident:
		return typed.Name
	case *ast.SelectorExpr:
		return typed.Sel.Name
	}
	return ""
}

// exprLabel renders a receiver for a message, collapsing anything that is not
// an identifier chain.
func exprLabel(expr ast.Expr) string {
	switch typed := unparen(expr).(type) {
	case *ast.Ident:
		return typed.Name
	case *ast.SelectorExpr:
		return exprLabel(typed.X) + "." + typed.Sel.Name
	case *ast.CallExpr:
		return exprLabel(typed.Fun) + "(...)"
	}
	return "<expression>"
}

// callPos returns the position a finding cites: the method name of a
// selector call, so a chain split across lines points at the call itself.
func callPos(call *ast.CallExpr) token.Pos {
	if selector, ok := unparen(call.Fun).(*ast.SelectorExpr); ok {
		return selector.Sel.Pos()
	}
	return call.Pos()
}

// transactionFix states the fix for a statement that is off the transaction.
func transactionFix(txName string) string {
	if txName == "_" {
		return "name the transaction parameter instead of _ and run the call on it or pass it to the call"
	}
	return "run it on " + txName + " or pass " + txName + " to it"
}

// unparen strips enclosing parentheses.
func unparen(expr ast.Expr) ast.Expr {
	for {
		paren, ok := expr.(*ast.ParenExpr)
		if !ok {
			return expr
		}
		expr = paren.X
	}
}
