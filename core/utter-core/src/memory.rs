//! Process memory probes used for model load/unload measurements.

/// Memory snapshot of the current process.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ProcessMemory {
    /// Resident set size.
    pub resident_bytes: u64,
    /// Physical footprint (what Activity Monitor calls "Memory"); includes
    /// Metal buffers on unified memory, which RSS can under-report.
    pub footprint_bytes: u64,
}

#[cfg(target_os = "macos")]
pub fn process_memory() -> ProcessMemory {
    let mut info = std::mem::MaybeUninit::<libc::rusage_info_v2>::zeroed();
    // SAFETY: proc_pid_rusage writes a rusage_info_v2 into the provided buffer
    // for flavor RUSAGE_INFO_V2; the buffer is correctly sized and aligned.
    let rc = unsafe {
        libc::proc_pid_rusage(
            libc::getpid(),
            libc::RUSAGE_INFO_V2,
            info.as_mut_ptr() as *mut libc::rusage_info_t,
        )
    };
    if rc != 0 {
        return ProcessMemory::default();
    }
    // SAFETY: rc == 0 means the kernel filled the struct.
    let info = unsafe { info.assume_init() };
    ProcessMemory { resident_bytes: info.ri_resident_size, footprint_bytes: info.ri_phys_footprint }
}

#[cfg(not(target_os = "macos"))]
pub fn process_memory() -> ProcessMemory {
    ProcessMemory::default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_nonzero_and_tracks_allocation() {
        let before = process_memory();
        assert!(before.resident_bytes > 0 && before.footprint_bytes > 0);
        let mut block = vec![0u8; 64 * 1024 * 1024];
        for page in block.chunks_mut(4096) {
            page[0] = 1; // touch every page so it is actually resident
        }
        let block = std::hint::black_box(block);
        let after = process_memory();
        assert!(after.footprint_bytes >= before.footprint_bytes + 32 * 1024 * 1024, "{before:?} -> {after:?}");
        drop(block);
    }
}
