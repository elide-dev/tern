fn main() {
    println!("cargo:rerun-if-changed=schema/embedding.capnp");
    capnpc::CompilerCommand::new()
        .src_prefix("schema")
        .import_path("schema")
        .file("schema/embedding.capnp")
        .run()
        .expect("embedding schema");
}
