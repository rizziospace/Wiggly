# Third-Party Notices

## Gifski

Wiggly includes Gifski, a high-quality animated GIF encoder based on
libimagequant.

- Project: https://github.com/ImageOptim/gifski
- Version: 1.35.0
- Source commit: `61ac230f65374c70f238cb35f9247cd22b4672f1`
- License: GNU Affero General Public License v3.0 or later
- License text: https://github.com/ImageOptim/gifski/blob/61ac230f65374c70f238cb35f9247cd22b4672f1/LICENSE

The vendored `ThirdParty/Gifski.xcframework` binaries were built from that
commit with:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
cargo build --release --lib --target aarch64-apple-ios --no-default-features
cargo build --release --lib --target aarch64-apple-ios-sim --no-default-features
```

The corresponding source is available from the commit URL above. Wiggly as a
combined work is distributed under AGPL-3.0-or-later.
