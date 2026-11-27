import ManagedSettings
import ManagedSettingsUI
import UIKit

/// The screen iOS shows when you open a locked app.
final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        makeConfiguration(appName: application.localizedDisplayName)
    }

    override func configuration(shielding application: Application,
                                in category: ActivityCategory) -> ShieldConfiguration {
        makeConfiguration(appName: application.localizedDisplayName)
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        makeConfiguration(appName: webDomain.domain)
    }

    override func configuration(shielding webDomain: WebDomain,
                                in category: ActivityCategory) -> ShieldConfiguration {
        makeConfiguration(appName: webDomain.domain)
    }

    private func makeConfiguration(appName: String?) -> ShieldConfiguration {
        let indigo = UIColor.systemIndigo
        return ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterial,
            backgroundColor: indigo.withAlphaComponent(0.15),
            icon: UIImage(systemName: "lock.fill")?.withTintColor(indigo, renderingMode: .alwaysOriginal),
            title: ShieldConfiguration.Label(text: "\(appName ?? "This app") is locked", color: .label),
            subtitle: ShieldConfiguration.Label(
                text: "Tap Unlock, then open the notification and confirm with Face ID.",
                color: .secondaryLabel),
            primaryButtonLabel: ShieldConfiguration.Label(text: "Unlock", color: .white),
            primaryButtonBackgroundColor: indigo,
            secondaryButtonLabel: ShieldConfiguration.Label(text: "Close", color: indigo)
        )
    }
}
