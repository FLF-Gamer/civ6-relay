#![cfg_attr(windows, windows_subsystem = "windows")]

// Quote one CreateProcess/CommandLineToArgvW argument, preserving UTF-16 exactly.
fn quote_argument(value: &[u16]) -> Vec<u16> {
    let mut result = vec![b'"' as u16];
    let mut slashes = 0;
    for &ch in value {
        if ch == b'\\' as u16 {
            slashes += 1;
            continue;
        }
        let count = if ch == b'"' as u16 { slashes * 2 + 1 } else { slashes };
        result.extend(std::iter::repeat_n(b'\\' as u16, count));
        result.push(ch);
        slashes = 0;
    }
    result.extend(std::iter::repeat_n(b'\\' as u16, slashes * 2));
    result.push(b'"' as u16);
    result
}

#[cfg(windows)]
mod windows {
    use super::quote_argument;
    use std::ffi::c_void;
    use std::mem::{size_of, zeroed};
    use std::os::windows::ffi::OsStrExt;
    use std::path::Path;
    use std::ptr::{null, null_mut};

    type Handle = *mut c_void;
    #[repr(C)]
    struct StartupInfo {
        cb: u32, reserved: *mut u16, desktop: *mut u16, title: *mut u16,
        x: u32, y: u32, width: u32, height: u32, x_chars: u32, y_chars: u32,
        fill: u32, flags: u32, show: u16, reserved_size: u16, reserved_data: *mut u8,
        stdin: Handle, stdout: Handle, stderr: Handle,
    }
    #[repr(C)]
    struct ProcessInfo { process: Handle, thread: Handle, process_id: u32, thread_id: u32 }

    #[link(name = "kernel32")]
    extern "system" {
        fn GetSystemDirectoryW(buffer: *mut u16, size: u32) -> u32;
        fn GetLastError() -> u32;
        fn CreateProcessW(application: *const u16, command: *mut u16,
            process_attributes: *const c_void, thread_attributes: *const c_void,
            inherit_handles: i32, flags: u32, environment: *const c_void,
            directory: *const u16, startup: *mut StartupInfo, process: *mut ProcessInfo) -> i32;
        fn WaitForSingleObject(handle: Handle, milliseconds: u32) -> u32;
        fn GetExitCodeProcess(handle: Handle, code: *mut u32) -> i32;
        fn CloseHandle(handle: Handle) -> i32;
    }
    #[link(name = "user32")]
    extern "system" { fn MessageBoxW(owner: Handle, text: *const u16, title: *const u16, flags: u32) -> i32; }

    struct OwnedHandle(Handle);
    impl Drop for OwnedHandle { fn drop(&mut self) { unsafe { CloseHandle(self.0); } } }

    fn terminated(mut value: Vec<u16>) -> Vec<u16> { value.push(0); value }
    fn wide(text: &str) -> Vec<u16> { terminated(text.encode_utf16().collect()) }
    fn path_wide(path: &Path) -> Vec<u16> { terminated(path.as_os_str().encode_wide().collect()) }

    fn error(text: &str, code: u32) -> u32 {
        let number = if code > 65535 { format!("0x{code:08X}") } else { code.to_string() };
        let message = wide(&format!("{text}\n\n错误代码：{number}"));
        let title = wide("核平联机助手");
        unsafe { MessageBoxW(null_mut(), message.as_ptr(), title.as_ptr(), 0x10 | 0x10000); }
        if code == 0 { 1 } else { code }
    }

    pub fn run() -> u32 {
        let executable = match std::env::current_exe() {
            Ok(path) => path,
            Err(_) => return error("无法确定启动器位置，请完整解压客户端后重试。", unsafe { GetLastError() }),
        };
        let directory = match executable.parent() {
            Some(path) => path,
            None => return error("无法确定客户端目录，请完整解压后重试。", 3),
        };
        let script = directory.join("Civ6Relay.ps1");
        if !script.is_file() { return error("找不到界面文件 Civ6Relay.ps1，请完整解压客户端后再启动。", 2); }

        let mut system = vec![0u16; 32768];
        let count = unsafe { GetSystemDirectoryW(system.as_mut_ptr(), system.len() as u32) } as usize;
        if count == 0 || count >= system.len() {
            return error("无法找到 Windows 系统目录，请检查系统组件。", unsafe { GetLastError() });
        }
        system.truncate(count);
        system.extend("\\WindowsPowerShell\\v1.0\\powershell.exe".encode_utf16());
        let application = terminated(system.clone());
        let mut arguments: Vec<Vec<u16>> = vec![system];
        for arg in ["-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File"] {
            arguments.push(arg.encode_utf16().collect());
        }
        arguments.push(script.as_os_str().encode_wide().collect());
        arguments.push("-Action".encode_utf16().collect());
        arguments.push("Gui".encode_utf16().collect());
        let mut command = Vec::new();
        for arg in arguments {
            if !command.is_empty() { command.push(b' ' as u16); }
            command.extend(quote_argument(&arg));
        }
        if command.len() >= 32767 { return error("客户端所在路径过长，请移到较短的目录后重试。", 206); }
        command.push(0);
        let cwd = path_wide(directory);
        let mut startup: StartupInfo = unsafe { zeroed() };
        startup.cb = size_of::<StartupInfo>() as u32;
        startup.flags = 1; // STARTF_USESHOWWINDOW, SW_HIDE (zero).
        let mut info: ProcessInfo = unsafe { zeroed() };
        let started = unsafe {
            CreateProcessW(application.as_ptr(), command.as_mut_ptr(), null(), null(), 0,
                0x08000000, null(), cwd.as_ptr(), &mut startup, &mut info) // CREATE_NO_WINDOW
        };
        if started == 0 { return error("无法启动 Windows PowerShell，请检查系统组件并重试。", unsafe { GetLastError() }); }
        let process = OwnedHandle(info.process);
        unsafe { CloseHandle(info.thread); }
        if unsafe { WaitForSingleObject(process.0, u32::MAX) } != 0 {
            return error("无法等待联机助手结束，请检查已打开的程序窗口。", unsafe { GetLastError() });
        }
        let mut code = 0;
        if unsafe { GetExitCodeProcess(process.0, &mut code) } == 0 {
            return error("无法读取联机助手的运行结果。", unsafe { GetLastError() });
        }
        if code != 0 { error("联机助手未能正常运行，请完整解压客户端后重试。", code); }
        code
    }
}

fn main() {
    #[cfg(windows)]
    std::process::exit(windows::run() as i32);
    #[cfg(not(windows))]
    panic!("This launcher is built for Windows only");
}

#[cfg(test)]
mod tests {
    use super::quote_argument;
    fn quoted(text: &str) -> String { String::from_utf16(&quote_argument(&text.encode_utf16().collect::<Vec<_>>())).unwrap() }
    #[test]
    fn preserves_unicode_spaces_and_shell_characters() {
        assert_eq!(quoted("C:\\玩家 甲 & 乙\\Civ6Relay.ps1"), "\"C:\\玩家 甲 & 乙\\Civ6Relay.ps1\"");
        assert_eq!(quoted(""), "\"\"");
    }
    #[test]
    fn escapes_quotes_and_trailing_backslashes() {
        assert_eq!(quoted("a\"b"), "\"a\\\"b\"");
        assert_eq!(quoted("C:\\目录\\"), "\"C:\\目录\\\\\"");
    }
}
