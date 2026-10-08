# Bundled Mermaid

`mermaid.min.js` is the unmodified standalone browser distribution from the official npm
`mermaid` package, version **12.1.0**, https://github.com/mermaid-js/mermaid.
It contains the upstream bundled dependency license notices; `LICENSE.txt` is Mermaid's MIT license.
No CDN, npm installation, dynamic imports or network access is needed at runtime.

To reproduce an update, run `npm pack mermaid@12.1.0` in a scratch directory, extract the
archive, and copy `package/dist/mermaid.min.js` and `package/LICENSE` here. Keep the complete
license comments in the distribution. Review upstream changes and rerun the shipping attachment
behavior/security/render tests before updating the pin.

SHA-256:

- npm tarball: `3e516f33246e1a6a5bc5ebcabd35434669b487c3b3791f9b0466aa2c254d004a`
- `mermaid.min.js`: `6484afc32872a3aa16cac9a76ba1816a1ed4cc870a6593cc2e17757750f518b2`

`index.html` and `viewer.js` are Threading's reader. The host supplies UTF-8 source as JavaScript
arguments, never executable source or an HTML interpolation. CSP denies network/file content,
the native navigation delegate accepts only the bundled entry page, and Mermaid's strict mode,
locked configuration and edge ceiling apply even to source-authored configuration directives.
