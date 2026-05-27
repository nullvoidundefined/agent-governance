# Styling Conventions

These rules apply to all frontend styling across every app in this portfolio.

---

## Stack

- **SCSS Modules** (`.module.scss`) for all component styles
- **Global SCSS** (`globals.scss`) for CSS custom properties, resets, and base styles
- **CSS Custom Properties** for theming (colors, spacing tokens)
- **No Tailwind**; never use utility classes
- **No BEM**; never use `block__element--modifier` naming
- **No CSS-in-JS**; no styled-components, emotion, or inline style objects
- **No plain CSS**; always use SCSS for the nesting and variable features

---

## File Structure

```
src/
├── app/
│   └── globals.scss                   # Custom properties, resets, base typography
├── styles/                            # (optional) Shared SCSS partials
│   ├── _variables.scss                # SCSS variables ($breakpoints, $radii, etc.)
│   └── _mixins.scss                   # Reusable mixins (responsive, truncate, etc.)
├── components/
│   └── ChatBox/
│       ├── ChatBox.tsx
│       └── ChatBox.module.scss        # Scoped styles for this component
```

- Every component has a co-located `.module.scss` file in the same folder
- Global styles live in `src/app/globals.scss`
- Shared SCSS partials (variables, mixins) live in `src/styles/` and are imported with `@use`
- Page-level styles use `camelCase.module.scss`: `tripDetail.module.scss`, `account.module.scss`

---

## CSS Custom Properties (Design Tokens)

Define all design tokens as CSS custom properties in `globals.scss`:

```scss
:root {
    // Colors
    --background: #ffffff;
    --foreground: #222222;
    --foreground-muted: #717171;
    --border: #ebebeb;
    --surface: #f7f7f7;
    --surface-alt: #f0f0f0;
    --surface-hover: #f0f0f0;
    --surface-active: #e0e0e0;
    --accent: #3b82f6;
    --accent-hover: #2563eb;
    --accent-light: #eff6ff;
    --background-translucent: rgba(255, 255, 255, 0.92);
}
```

### Rules

- All colors come from custom properties; never hardcode hex values in component SCSS
- Exception: pure white (`#fff`) and error red (`#ef4444`) may be used directly
- Token names use kebab-case: `--foreground-muted`, `--surface-hover`
- Semantic naming; describe purpose, not appearance: `--accent` not `--blue`

---

## Class Naming (SCSS Modules)

Use **camelCase** for all class names:

```scss
// ChatBox.module.scss
.chatBox { ... }
.messageList { ... }
.inputArea { ... }
.sendButton { ... }
.toolProgress { ... }
.roleBadge { ... }
```

### Rules

- **camelCase** for all class names: `.chatBox`, `.messageList`, `.primaryCta`
- **No BEM**: never use `__` or `--` in class names
- **No kebab-case**: never use `.chat-box` or `.message-list`
- Variant classes are separate: `.chip` + `.chipSelected`, not `.chip--selected`
- State classes are also camelCase: `.active`, `.disabled`, `.loading`
- Screen-reader-only utility: `.srOnly`

### Applying Variants

Use separate class names and compose them in JSX:

```scss
// SCSS
.chip { ... }
.chipSelected {
    background: var(--accent);
    border-color: var(--accent);
    color: #fff;
}
```

```tsx
// TSX
<button className={`${styles.chip} ${selected ? styles.chipSelected : ''}`}>
```

---

## SCSS Nesting

Use SCSS nesting for:
1. **Pseudo-classes and pseudo-elements** (`&:hover`, `&::before`)
2. **State modifiers via parent selector** (`.user &`, `.assistant &`)
3. **Direct child elements** (`p`, `span`, `input` inside a scoped class)
4. **Media queries** (nested inside the class they modify)

```scss
.bubble {
    padding: 12px 16px;
    border-radius: 12px;
    font-size: 14px;
    line-height: 1.6;

    p {
        margin: 0;

        &:empty {
            height: 8px;
        }
    }
}

.user .bubble {
    background: var(--accent);
    color: #fff;
    border-bottom-right-radius: 4px;
}

.navLink {
    padding: 8px 16px;
    color: var(--foreground-muted);
    transition: background 0.15s, color 0.15s;

    &:hover {
        background: var(--surface-hover);
        color: var(--foreground);
    }

    &.active {
        background: var(--surface-active);
        font-weight: 600;
    }
}
```

### Rules

- Nest only 2 levels deep maximum (excluding pseudo-classes)
- Use `&` for pseudo-classes, pseudo-elements, and `.compoundSelector`
- Use parent selector patterns for contextual styling: `.user .bubble { ... }`
- Never nest more than 3 levels; flatten and create a new class instead

---

## Responsive Design

Use `@media` queries nested inside the class they modify:

```scss
.features {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 24px;
}

@media (max-width: 800px) {
    .features {
        grid-template-columns: repeat(2, 1fr);
        gap: 16px;
    }
}

@media (max-width: 480px) {
    .features {
        grid-template-columns: 1fr;
    }
}
```

### Breakpoints

Use these standard breakpoints consistently:

```scss
// In _variables.scss or directly in modules
$bp-mobile: 480px;
$bp-tablet: 800px;
$bp-desktop: 1200px;
```

- Mobile-first is not required; use `max-width` media queries (desktop-first)
- Breakpoints go at the bottom of the module file, grouped together
- Breakpoint values: `480px` (mobile), `800px` (tablet), `1200px` (desktop)

---

## Spacing & Sizing

- Use `px` values directly; no rem/em conversion required
- Common spacing scale: `4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 80`
- Border radius scale: `4px` (subtle), `8px` (standard), `10px` (buttons), `12px` (cards), `16px` (large cards), `20px` (pills), `50%` (circles)
- Max content width: `1400px` with `margin: 0 auto`
- Page padding: `24px` horizontal, reduced to `16px` on mobile

---

## Typography

- Font: `var(--font-geist-sans), system-ui, sans-serif` (set in `globals.scss`)
- Base size: `14px` for body text
- Scale: `11px` (badges), `12px` (captions), `13px` (small text), `14px` (body), `15px` (form labels), `16px` (subheadings), `18px` (subtitles), `20px` (nav logo), `28px` (section titles), `32px` (mobile hero), `48px` (desktop hero)
- Font weights: `400` (normal), `500` (medium), `600` (semibold), `700` (bold), `800` (extra-bold, hero titles only)
- Letter spacing: `-0.03em` (hero), `-0.02em` (headings), `0.05em` (uppercase labels)
- Line heights: `1.1` (hero), `1.5` (body/small), `1.6` (paragraph/bubble)

---

## Transitions & Animations

- Standard transition: `transition: background 0.15s` or `transition: color 0.15s`
- Multiple properties: `transition: background 0.15s, color 0.15s, border-color 0.15s`
- Duration: `0.15s` for hover states, `0.2s` for state changes
- Easing: default (ease); don't specify unless needed
- Keyframe animations use camelCase: `@keyframes typingDot { ... }`

---

## Interactive Elements

### Buttons

```scss
.primaryButton {
    padding: 12px 28px;
    border: none;
    border-radius: 10px;
    background: var(--accent);
    color: #fff;
    font-size: 15px;
    font-weight: 600;
    font-family: inherit;
    cursor: pointer;
    transition: background 0.15s;

    &:hover:not(:disabled) {
        background: var(--accent-hover);
    }

    &:disabled {
        opacity: 0.5;
        cursor: not-allowed;
    }
}
```

### Inputs

```scss
.input {
    padding: 10px 14px;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--surface);
    color: var(--foreground);
    font-size: 14px;
    font-family: inherit;
    outline: none;
    transition: border-color 0.15s;

    &::placeholder {
        color: var(--foreground-muted);
        opacity: 0.6;
    }

    &:focus {
        border-color: var(--accent);
    }
}
```

### Rules for all interactive elements

- Always set `font-family: inherit`
- Always set `cursor: pointer` on clickable elements
- Always handle `:disabled` state with `opacity` + `cursor: not-allowed`
- Use `:hover:not(:disabled)` pattern to prevent hover styles on disabled elements
- Use `outline: none` on inputs, with `border-color` change on `:focus`

---

## Global Reset (`globals.scss`)

```scss
:root {
    // Design tokens here
}

html,
body {
    max-width: 100vw;
    overflow-x: hidden;
}

body {
    color: var(--foreground);
    background: var(--background);
    font-family: var(--font-geist-sans), system-ui, sans-serif;
    -webkit-font-smoothing: antialiased;
    -moz-osx-font-smoothing: grayscale;
}

* {
    box-sizing: border-box;
    padding: 0;
    margin: 0;
}

a {
    color: inherit;
    text-decoration: none;
}
```

---

## Section Separators in SCSS

Use comment blocks to organize sections within larger module files:

```scss
/* ---- Google button ---- */

.googleButton { ... }

/* ---- Divider ---- */

.divider { ... }

/* ---- Form ---- */

.form { ... }
```

- Format: `/* ---- Section Name ---- */`
- Blank line before and after the comment
- Use for files with 100+ lines to improve scanability

---

## SCSS Module Import in TSX

```tsx
import styles from './ChatBox.module.scss';

// Single class
<div className={styles.chatBox}>

// Multiple classes
<div className={`${styles.message} ${styles.user}`}>

// Conditional class
<button className={`${styles.chip} ${selected ? styles.chipSelected : ''}`}>
```

- Import as `styles` (always this name)
- Access classes via `styles.camelCaseName`
- Compose with template literals for multiple/conditional classes
- Never use `classnames` or `clsx` libraries; template literals are sufficient

---

## Formatting

- **4-space indentation** (matches TypeScript/Prettier config)
- Properties ordered by box model: position → display → sizing → spacing → border → background → typography → transition/animation
- One declaration per line
- Opening brace on same line as selector
- Blank line between rule blocks
- Trailing semicolons on all declarations
