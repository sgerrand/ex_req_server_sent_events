# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [0.2.3](https://github.com/sgerrand/ex_req_server_sent_events/compare/v0.2.2...v0.2.3) (2026-08-21)


### Bug Fixes

* **deps:** bump req from 0.6.2 to 0.7.2 ([#24](https://github.com/sgerrand/ex_req_server_sent_events/issues/24)) ([9e2cf73](https://github.com/sgerrand/ex_req_server_sent_events/commit/9e2cf73a003e2ccd1e4a9d935061769e369c42b6))

## [0.2.2](https://github.com/sgerrand/ex_req_server_sent_events/compare/v0.2.1...v0.2.2) (2026-07-18)


### Bug Fixes

* **deps:** bump req from 0.5.18 to 0.6.1 ([#15](https://github.com/sgerrand/ex_req_server_sent_events/issues/15)) ([e849ed1](https://github.com/sgerrand/ex_req_server_sent_events/commit/e849ed11a81a3889ecc4a01fc2afb67e699ce4ac))
* **deps:** bump req from 0.6.1 to 0.6.2 ([#18](https://github.com/sgerrand/ex_req_server_sent_events/issues/18)) ([852ffc6](https://github.com/sgerrand/ex_req_server_sent_events/commit/852ffc674c93182c43acb377181f6d81a953afbe))

## [0.2.1](https://github.com/sgerrand/ex_req_server_sent_events/compare/v0.2.0...v0.2.1) (2026-06-14)


### Bug Fixes

* **deps:** bump req from 0.5.17 to 0.5.18 ([#6](https://github.com/sgerrand/ex_req_server_sent_events/issues/6)) ([f73ce0f](https://github.com/sgerrand/ex_req_server_sent_events/commit/f73ce0f5d8ca42f1caae2773bb0cda36b3401d8d))
* **frame:** handle bare CR as line terminator in parse/1 ([001f4da](https://github.com/sgerrand/ex_req_server_sent_events/commit/001f4daeba628fe34514d4da3f487f1655313639))
* **frame:** restore single-pattern split fast path for LF buffers ([c90dce1](https://github.com/sgerrand/ex_req_server_sent_events/commit/c90dce189961278fedf6995ed2b4fa472e1886b2))


### Performance Improvements

* **frame:** split on multi-pattern delimiters without normalising ([926d4a0](https://github.com/sgerrand/ex_req_server_sent_events/commit/926d4a0db23d6095d61d548d4fa31d14f39d0147))

## [0.2.0](https://github.com/sgerrand/ex_req_server_sent_events/compare/v0.1.0...v0.2.0) (2026-05-03)


### Features

* **plugin:** add :max_frame_size option to attach/2 ([5a089cf](https://github.com/sgerrand/ex_req_server_sent_events/commit/5a089cf41bb4622744d71eaa40d0b8416e4dc535))
* **plugin:** emit telemetry events for streams and frames ([cafd0f1](https://github.com/sgerrand/ex_req_server_sent_events/commit/cafd0f16fb2e945eac2fea8367011f4c9a043956))


### Bug Fixes

* **frame:** align parser with SSE spec ([c3b0c5a](https://github.com/sgerrand/ex_req_server_sent_events/commit/c3b0c5a7a315d4ed42d0a5e5f7d55556b51340f7))
* **frame:** normalise CRLF line endings and fix O(n²) comment accumulation ([2b5e609](https://github.com/sgerrand/ex_req_server_sent_events/commit/2b5e6097faae4caa0900e38f8d74dd1705cbc1f5))
* **plugin:** populate sse_ref on response in sse_done step ([4e43c6e](https://github.com/sgerrand/ex_req_server_sent_events/commit/4e43c6e9ca225f926a01c3aecd9bdc273eedad66))
* resolve credo strict nesting depth violation in wrap_fun ([af13935](https://github.com/sgerrand/ex_req_server_sent_events/commit/af1393525a297e17080925394a50ddb6635a3dfb))

## 0.1.0 (2026-04-30)

Initial release.
