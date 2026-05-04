# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


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
