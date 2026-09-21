/// Default bundle ids excluded from clipboard history: well-known password managers and autofill
/// tools. This is only a starting point — user-editable in Settings → Privacy.
public enum ExclusionSeeds {
    public static let passwordManagers: [String] = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.dashlane.dashlanephonefinal",
        "com.lastpass.LastPass",
        "org.keepassxc.keepassxc",
        "in.sinew.Enpass-Desktop",
        "com.nordpass.macos",
        "me.proton.pass.electron",
        "com.markmcguill.strongbox.mac",
    ]
}
