### Added

- `:connect_options` configuration option, passed through to `Req.post` so the
  HTTP connection used to push to Loki can be customised (connect timeout,
  `:protocols`, `:transport_opts` for SSL/TLS, `:proxy`, etc.). See the keys
  documented under `:connect_options` in the Req docs.
  Thanks to [@gabrielmancini](https://github.com/gabrielmancini).
