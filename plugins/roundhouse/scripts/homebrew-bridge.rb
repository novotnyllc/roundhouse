# frozen_string_literal: true

# Loaded only by Machine Utilities' ordinary-user cask transaction. Homebrew
# owns its normal download, checksum, rollback, and Caskroom metadata flow; its
# attempted sudo is redirected to the installed root broker's typed bridge.
require "system_command"
require "cask/artifact/abstract_uninstall"

module MachineUtilitiesHomebrewSudoBridge
  BROKER = "/usr/local/libexec/machine-utilities/posix-broker"

  def sudo_prefix
    ["/usr/bin/sudo", "-n", "--", BROKER, "--homebrew-bridge-v1"]
  end
end

module MachineUtilitiesHomebrewPkgUpgrade
  # Package deletion is a separate, open-ended root surface in Homebrew. The
  # exact enrolled vendor package performs the upgrade; V1 does not authorize
  # Homebrew's receipt-pattern-driven root deletion pass.
  def uninstall_pkgutil(*_packages, **_options)
    ohai "Preserving prior package receipts for the sealed package installer"
  end
end

SystemCommand.prepend(MachineUtilitiesHomebrewSudoBridge)
Cask::Artifact::AbstractUninstall.prepend(MachineUtilitiesHomebrewPkgUpgrade)
