---
name: react_component
keywords: [react, component, ui, tsx, jsx, button, form, modal, card, list, table, input, dropdown]
file_patterns: ["src/components/*", "components/*", "app/**/components/*", "*.tsx"]
---

# React Component Creation

Use this pattern when creating or modifying React components, including UI elements, forms, modals, and reusable widgets.

## Steps Template

1. Read existing components in src/components/ to understand patterns and conventions
2. Create the component file with proper TypeScript props interface
3. Implement the component with appropriate state management (if needed)
4. Add styling using project's CSS approach (Tailwind, CSS modules, etc.)
5. Export component and add to index file if using barrel exports
6. Verify typecheck passes with: npx tsc --noEmit

## Relevant Files

- src/components/ - Component directory
- src/components/ui/ - Base UI components
- src/hooks/ - Custom hooks
- tailwind.config.js - Tailwind configuration (if using)

## Gotchas

- **Props interface** should be explicit and exported for reuse
- **Default exports vs named exports** - follow project convention
- **Client components** need "use client" directive if using hooks/state
- **Event handlers** should be typed: `onClick: (e: React.MouseEvent) => void`
- **Conditional rendering** - prefer early returns over nested ternaries
- **Key prop** required for mapped elements: `key={item.id}`
- **Accessibility** - add aria labels, roles, keyboard handlers
- **Memoization** - use `React.memo()` for expensive pure components
- **State location** - lift state up when multiple components need it
- **Composition** - prefer composition over prop drilling with children
