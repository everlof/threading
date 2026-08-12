---
title: Themes
description: Change visual identity while preserving application structure and behavior.
group: Customize
order: 90
---

# Themes

Themes can change the atmosphere of the app without changing how features
work. They own semantic visual tokens; feature views own layout, hierarchy,
interaction, and behavior.

## What a theme can define

A theme can provide:

- semantic colors for ground, surfaces, panels, borders, labels, accents,
  controls, selections, statuses, and syntax;
- light or dark appearance;
- panel and control geometry;
- border treatment and restrained glow or shadow;
- an optional app-drawn window frame and command band;
- a supported typeface category;
- a complete terminal palette;
- optional app and Dock artwork where supported.

Semantic roles let every surface respond coherently. A permission warning,
selected session, terminal cursor, and Git review panel should belong to the
same visual identity without each feature knowing the theme’s literal colors.

## What a theme cannot define

A theme does not move the sidebar, replace native controls with arbitrary
subclasses, change approval behavior, or own feature-specific layout. Those
boundaries keep themes compatible with accessibility, keyboard navigation,
new features, and the iOS companion.

## System and stock themes

System follows the platform appearance and remains the safe application
default. Stock themes provide more directed identities, including Threading,
Editorial, Cyberpunk, Swiss Minimalist, Bauhaus, Art Deco, Neo Brutalism,
Claymorphism, Vaporwave, Newsprint, Botanical, Industrial, and Christmas.

## Threading

Threading is a dark stock theme with navy surfaces, warm text, and orange
accents. It also draws the Mac window frame, title band, window controls, and
command band with the same palette. Selected rows use a deeper navy so orange
can stay reserved for actions, focus, and the active window seam. Its terminal
palette and iPhone projection use the same colors, so native controls and a
provider TUI sit in one consistent frame.

## Editorial

Editorial is a dark theme built from warm ink, cognac orange, powder blue,
deep teal, and cream, with warm serif typography and restrained glow.

## Extension themes

Extensions can package themes and fonts through the same declared extension
model. A contributed theme still uses host-defined semantic roles and does not
receive a separate path around application interface boundaries.
