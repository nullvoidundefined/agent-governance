---
paths:
  - "**/*.scss"
  - "**/*.module.css"
  - "**/*.tsx"
  - "**/*.jsx"
  - "**/*.vue"
---

# Styling Conventions

## Styling policy

- SCSS Modules (`.module.scss`) plus CSS custom properties are the default for all JS/TS frontend styling.
- Do not introduce Tailwind or any utility-first CSS framework, CSS-in-JS (styled-components, emotion, vanilla-extract, inline style objects), or any other styling framework or component-styling library, unless the owner explicitly asks for it. A new styling package is an owner decision.
- If the repository already uses a different styling system, keep using it and match it. Do not migrate it, mix a second system in, or convert it to SCSS Modules without an explicit owner request.
- Extend the existing design tokens, custom properties, mixins and partials. Do not replace them, fork a parallel token set, or hardcode a value a token already names.
- No BEM, no plain `.css` for new component styles, no `classnames`/`clsx`.

## Files

- Each component has a co-located `ComponentName.module.scss`. A repo that already uses `.module.css` keeps it.
- Global tokens and resets live in the framework's global stylesheet (`globals.scss` in Next and Vite, `main.scss` in Nuxt). Shared partials live in `styles/` and load with `@use`.
- Import the module as `styles`. A Vue SFC imports its sibling file in `<script setup>`; never a `<style>` or `<style module>` block.
- Compose classes with template literals in TSX and the `:class` array form in Vue.

## Tokens and class names

- Colors, spacing, radii and breakpoints come from the repo's existing custom properties and SCSS variables. Where no token exists, add one rather than hardcoding the value.
- Token names are semantic: `--accent`, not `--blue`. Theme switches on a `data-theme` attribute on `<html>`.
- Class names are camelCase (`.chatBox`, `.chipSelected`) so `styles.chatBox` works without bracket access.
- Keep selectors shallow; when nesting gets hard to read, flatten into a new class.

## Accessibility

- Never remove a focus indicator without an equally visible replacement. Style `:focus-visible`; do not ship `outline: none` on its own.
- Clickable things are native controls or the repo's primitives, never a styled `<div>`.
