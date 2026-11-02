use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn resource_compiler() -> PathBuf {
    if let Some(path) = env::var_os("RC") { return path.into(); }
    if !cfg!(windows) { return "llvm-rc".into(); }
    if Command::new("rc.exe").arg("/?").output().is_ok() { return "rc.exe".into(); }
    let mut roots = Vec::new();
    if let Some(path) = env::var_os("WindowsSdkDir") { roots.push(PathBuf::from(path).join("bin")); }
    if let Some(path) = env::var_os("ProgramFiles(x86)") {
        roots.push(PathBuf::from(path).join("Windows Kits/10/bin"));
    }
    for root in roots {
        let mut versions: Vec<_> = fs::read_dir(root).into_iter().flatten().flatten().map(|entry| entry.path()).collect();
        versions.sort();
        for version in versions.into_iter().rev() {
            for host in ["x64", "x86"] {
                let compiler = version.join(host).join("rc.exe");
                if compiler.is_file() { return compiler; }
            }
        }
    }
    panic!("Windows SDK rc.exe was not found; install the Windows SDK or set RC");
}

fn rc_path(path: &Path) -> String { path.to_string_lossy().replace('\\', "/").replace('"', "\\\"") }

fn main() {
    for name in ["app.manifest", "icon.ico", "Cargo.toml", "build.rs"] {
        println!("cargo:rerun-if-changed={name}");
    }
    println!("cargo:rerun-if-env-changed=RC");
    // Unit-test executables do not need UAC elevation. Release binaries always do.
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") || env::var("PROFILE").as_deref() != Ok("release") { return; }
    let root = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let output = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let version = env::var("CARGO_PKG_VERSION").unwrap();
    let numeric = version.split('-').next().unwrap().replace('.', ",") + ",0";
    // Wide escapes keep the product name identical in rc.exe and llvm-rc.
    let product_name = "核平联机助手".encode_utf16().map(|code| format!("\\x{code:04x}")).collect::<String>();
    let resource = format!(r#"1 24 "{manifest}"
1 ICON "{icon}"
1 VERSIONINFO
FILEVERSION {numeric}
PRODUCTVERSION {numeric}
FILEFLAGSMASK 0x3fL
FILEFLAGS 0
FILEOS 0x40004L
FILETYPE 1
FILESUBTYPE 0
BEGIN
 BLOCK "StringFileInfo"
 BEGIN
  BLOCK "040904b0"
  BEGIN
   VALUE "FileDescription", L"{product_name}\0"
   VALUE "FileVersion", "{version}\0"
   VALUE "ProductName", L"{product_name}\0"
   VALUE "ProductVersion", "{version}\0"
   VALUE "OriginalFilename", "Civ6Relay.exe\0"
  END
 END
 BLOCK "VarFileInfo"
 BEGIN
  VALUE "Translation", 0x0409, 1200
 END
END
"#, manifest=rc_path(&root.join("app.manifest")), icon=rc_path(&root.join("icon.ico")));
    let rc = output.join("launcher.rc");
    let res = output.join("launcher.res");
    fs::write(&rc, resource).unwrap();
    let status = Command::new(resource_compiler()).arg("/nologo").arg("/fo").arg(&res).arg(&rc).status().expect("Resource compiler could not start");
    assert!(status.success(), "Resource compilation failed");
    println!("cargo:rustc-link-arg={}", res.display());
    println!("cargo:rustc-link-arg=/Brepro");
    println!("cargo:rustc-link-arg=/DEBUG:NONE");
    println!("cargo:rustc-link-arg=/PDBALTPATH:Civ6Relay.pdb");
}
