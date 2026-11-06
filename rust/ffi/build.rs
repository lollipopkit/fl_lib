use std::env;

fn main() {
    // Android 15 devices ship with a 16 KB page size, and a cdylib linked for
    // 4 KB pages fails to load on them (`dlopen` ENOEXEC). fl_tty's hook and
    // fl_pi_llm's build.rs pass the same flag for their libraries.
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {
        println!("cargo:rustc-cdylib-link-arg=-Wl,-z,max-page-size=16384");
    }
}
