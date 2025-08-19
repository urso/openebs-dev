# SPDK-RS Application Setup Example

Shows proper SPDK application initialization including argument parsing, reactor setup, and lifecycle management.

## Application Initialization
**Source:** `examples/hello_world.rs:30-78` + `src/libspdk/`

Initialize SPDK application with proper options:

```rust
let mut opts: spdk_app_opts = zeroed();
spdk_app_opts_init(&mut opts, size_of::<spdk_app_opts>());
opts.name = CString::new("app_name")?.into_raw();
```

## Argument Parsing
**Source:** `src/libspdk/`

Parse SPDK command line arguments and options:

```rust
let rc = spdk_app_parse_args(argc, argv, &mut opts, 
    Some(parse_arg), Some(usage_cb));
assert_eq!(rc, SPDK_APP_PARSE_ARGS_SUCCESS);
```

## Application Lifecycle  
**Source:** `examples/hello_world.rs:67-77`

Start application with main callback and handle lifecycle:

```rust
spdk_app_start(&mut opts, Some(app_main), null_mut()); // Start app
spdk_app_fini();                                       // Final cleanup
```