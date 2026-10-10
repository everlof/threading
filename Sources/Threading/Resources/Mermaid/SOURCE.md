# Bundled Mermaid

`mermaid.tiny.js` is the unmodified browser distribution from the official npm package
`@mermaid-js/tiny`, version **12.1.0**, built from the same release of
https://github.com/mermaid-js/mermaid as the full `mermaid` package and published by the same
maintainers. It is Mermaid without the mindmap and architecture diagrams (and so without
cytoscape, which only they use), without KaTeX math rendering and without lazy loading. Those
diagram types fail to parse here and the reader shows their source, as it does for any invalid
diagram.

It replaced the full `mermaid.min.js` (5.49 MB; about 1.57 MB as compressed in the update zip)
on 2026-10-08, to halve the reader's share of the app: the tiny build is 2.81 MB, about 0.75 MB
compressed. See [`bundle-size-levers.md`](../../../../docs/decisions/bundle-size-levers.md).
It contains the upstream bundled dependency license notices (DOMPurify, lodash); `LICENSE.txt` is
Mermaid's MIT license, identical in both packages. No CDN, npm installation, dynamic imports or
network access is needed at runtime.

To reproduce an update, run `npm pack @mermaid-js/tiny@<version>` in a scratch directory, check
the tarball against `npm view @mermaid-js/tiny@<version> dist.integrity`, extract it, and copy
`package/dist/mermaid.tiny.js` and `package/LICENSE` here. Keep the complete license comments in
the distribution. Review upstream changes and rerun the shipping attachment
behavior/security/render tests before updating the pin. Moving back to the full package is the
same procedure with `mermaid@<version>` and `package/dist/mermaid.min.js`, plus the `<script>` in
`index.html`.

SHA-256:

- npm tarball: `86104f6dd76232669e140205021584763df40e32dbc25e285f26e7bde4bcdfe8`
  (registry integrity `sha512-z/N9vnXv+5Ffcdj19viXxPhSy7Jt5y4vtS+Aa9iZVGIo2U0KKNgO2U+xm8plHh3y5eUVkschMCXfc/DIz8A6uQ==`)
- `mermaid.tiny.js`: `143c1b9345c45963ff429da4bdcd9051316a43522ea9edd7ccb7a87ff947a804`

`index.html` and `viewer.js` are Threading's reader. The host supplies UTF-8 source as JavaScript
arguments, never executable source or an HTML interpolation. CSP denies network/file content,
the native navigation delegate accepts only the bundled entry page, and Mermaid's strict mode,
locked configuration and edge ceiling apply even to source-authored configuration directives.
The `secure` list in `viewer.js` names `dompurifyConfig` and every per-diagram `*FontFamily` key;
re-check upstream's config schema for new keys of either kind when updating the pin. A theme face
registered only in Threading's process crosses as bytes into a `FontFace`, never as a font URL.
