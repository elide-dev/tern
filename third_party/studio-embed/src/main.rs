use std::{
    io::{self, Write},
    path::PathBuf,
};
use studio_embed::{read_frame, write_frame, MAX_REQUEST};

fn main() {
    if let Err(error) = run() {
        eprintln!("Embedded Elide worker: {error}");
        std::process::exit(1);
    }
}
fn run() -> Result<(), String> {
    let mut args = std::env::args_os().skip(1);
    let home = PathBuf::from(args.next().ok_or("Provide an SDK directory")?);
    if args.next().is_some() {
        return Err("Unexpected worker argument".into());
    }
    let mut session = studio_embed::Session::open(&home)?;
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    while let Some(request) = read_frame(&mut input, MAX_REQUEST).map_err(|e| e.to_string())? {
        let response = session.exchange(&request)?;
        write_frame(&mut output, &response).map_err(|e| e.to_string())?;
        output.flush().map_err(|e| e.to_string())?;
    }
    Ok(())
}
