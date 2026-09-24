uniffi::setup_scaffolding!();

#[uniffi::export]
pub fn core_version() -> String {
    utter_core::runtime_version()
}
