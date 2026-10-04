---
title: Themes
description: Change visual identity while preserving application structure and behavior.
group: Customize
order: 90
---

# Themes

Themes change how the app looks and leave how features work alone. A theme
owns semantic visual tokens, and feature views own layout, hierarchy,
interaction, and behavior.

## What a theme can define

A theme can provide:

- semantic colors for ground, surfaces, panels, borders, labels, accents,
  controls, selections, statuses, and syntax;
- light or dark appearance;
- panel and control geometry;
- border treatment and restrained glow or shadow;
- an optional app-drawn window frame and command band;
- its own fonts;
- a complete terminal palette;
- a gradient or picture under the panes and the sidebar;
- drifting particles, a transition when you switch to it, sounds, and a
  sidebar mascot that changes pose with what your agents are doing;
- optional app and Dock artwork where supported.

Because every surface reads semantic roles, a permission warning, a selected
session, the terminal cursor, and the Git Review panel all take the theme's
colors without any feature knowing them.

## What a theme cannot define

A theme does not move the sidebar, replace native controls with arbitrary
subclasses, change approval behavior, or own feature-specific layout. Those
limits keep every theme working with accessibility, keyboard navigation, new
features, and the iOS companion.

## System and stock themes

New installs start with **Threading**. **System** is the unstyled option that
uses plain macOS colors. The picker groups 28 built-in themes:

- **Threading**, the house theme;
- **Design styles:** Editorial, Cyberpunk, Swiss Minimalist, Bauhaus, Art
  Deco, Neo Brutalism, Claymorphism, Vaporwave, Newsprint, Botanical, and
  Industrial;
- **Palettes:** Pure, Cappuccino, Solarized, Nord, and Dracula;
- **Classic desktops:** Mac OS 9 Platinum, Mac OS X Aqua, Mac OS X 10.4
  Tiger, BeOS R5, OPENSTEP 4.2, IRIX Indigo Magic, Amiga Workbench 3.1, and
  Windows 98;
- **Classic software:** Classic Player and TUI;
- **Seasonal:** Christmas.

You can set a theme for the whole app, a project, or a single session.
**Duplicate to Edit** makes an editable copy of any built-in theme.

## Threading

Threading is the default theme. It follows the Mac's appearance: warm paper
in light mode and navy in dark mode, with orange accents and the native macOS
title bar in both. Its terminal palette and iPhone projection use the same
colors, so native controls and a provider TUI share one frame.

## Editorial

Editorial is a dark theme built from warm ink, cognac orange, powder blue,
deep teal, and cream, with warm serif typography and restrained glow.

## Motion and music

Theme particles, transitions, and drifting gradients stop under **Theme
animations** in Themes settings, Reduce Motion, or Low Power Mode.
**Music-reactive themes**, off by default, let a theme react to audio from the
whole system or one app. It needs macOS 14.2 or later and the System Audio
Recording permission. Threading analyzes the audio on the Mac and passes only
levels to the theme.

## Themes from agents

Agents can list, set, and create themes through Threading's theme tools. Ask
the session to "make my theme warmer" or "make it look like a submarine
control room" and it edits a custom copy while you watch. An agent never
overwrites an existing theme, and Threading refuses a palette whose text is
unreadable against its background.

## Extension themes

Extensions can package themes and fonts through the same declared extension
model. A contributed theme still uses host-defined semantic roles and does not
receive a separate path around application interface boundaries.
