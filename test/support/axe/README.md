# axe-core test artifact

`axe-4.12.1.min.js` is the unmodified `axe.min.js` from the npm package
`axe-core@4.12.1`. It is test-only and is not served by the application.

- Package: <https://registry.npmjs.org/axe-core/-/axe-core-4.12.1.tgz>
- npm SHA-512 (hex): `b3b8867f919a54cc441b410d37dc7ec53afb1856426f564fff5b804d4a4210ad97efc9c30774706ed142a3da4601ff6bbbe570a10e3ae0391a2c4791334f3024`
- Vendored file SHA-256: `66a8aaa95a8b044a7fd74a5435873bf04ff65a1ca75567c921b7509742085a14`

`AccessibilityTestHelper` verifies the file SHA-256 before every audit. To
update it, verify the npm package integrity from registry metadata before
extracting `package/axe.min.js`, then update the version and independently
computed digest in this file, the `.sha256` manifest, and the helper.
