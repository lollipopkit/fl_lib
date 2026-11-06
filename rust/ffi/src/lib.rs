//! fl_lib's Rust for Dart: `api` is what `flutter_rust_bridge_codegen`
//! generates bindings from (`lib/src/rust/`, never edited by hand).

// Errors cross to Dart by value, once: their size costs nothing here.
#![allow(clippy::result_large_err)]

pub mod api;
mod frb_generated;
mod lkc_bridge;
