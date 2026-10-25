// No console window beside the app on Windows, in a release build
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    kupcad_app_lib::run()
}
