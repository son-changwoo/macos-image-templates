packer {
  required_plugins {
    tart = {
      version = ">= 1.14.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "macos_version" {
  type = string
  default = "sonoma"
}

variable "xcode_version" {
  type = list(string)
  default = ["16.2"]
}

variable "additional_runtimes" {
  type = list(string)
  default = []
}

variable "tag" {
  type = string
  default = ""
}

variable "disk_size" {
  type = number
  default = 200
}

variable "disk_free_mb" {
  type = number
  default = 60000
}

source "tart-cli" "tart" {
  vm_base_name = "ghcr.io/cirruslabs/macos-${var.macos_version}-base:latest"
  // use tag or the last element of the xcode_version list
  vm_name      = "${var.macos_version}-xcode:${var.tag != "" ? var.tag : var.xcode_version[0]}"
  cpu_count    = 4
  memory_gb    = 16
  disk_size_gb = var.disk_size
  headless     = true
  ssh_password = "admin"
  ssh_username = "admin"
  ssh_timeout  = "120s"
}

locals {
  xcode_install_provisioners = [
    for version in reverse(sort(var.xcode_version)) : {
      type = "shell"
      inline = [
        "source ~/.zprofile",
        "sudo xcodes install ${version} --experimental-unxip --path /Users/admin/Downloads/Xcode_${version}.xip --select --empty-trash",
        // get selected xcode path, strip /Contents/Developer and move to GitHub compatible locations
        "INSTALLED_PATH=$(xcodes select -p)",
        "CONTENTS_DIR=$(dirname $INSTALLED_PATH)",
        "APP_DIR=$(dirname $CONTENTS_DIR)",
        "sudo mv $APP_DIR /Applications/Xcode_${version}.app",
        "sudo xcode-select -s /Applications/Xcode_${version}.app",
        "xcodebuild -downloadPlatform iOS",
        "xcodebuild -runFirstLaunch",
        "sudo xcodebuild -license accept",
        "sudo DevToolsSecurity -enable",
      ]
    }
  ]
}

build {
  sources = ["source.tart-cli.tart"]

  provisioner "shell" {
    inline = [
      "source ~/.zprofile",
      "brew --version",
      "brew update",
      "brew upgrade",
    ]
  }

  // Re-install the GitHub Actions runner
  provisioner "shell" {
    script = "scripts/install-actions-runner.sh"
  }

  // make sure our workaround from base is still valid
  provisioner "shell" {
    inline = [
      "sudo ln -s /Users/admin /Users/runner || true"
    ]
  }

  provisioner "shell" {
    inline = [
      "source ~/.zprofile",
      "brew install xcodesorg/made/xcodes",
      "xcodes version",
    ]
  }

  provisioner "file" {
    sources      = [ for version in var.xcode_version : pathexpand("~/Downloads/Xcode_${version}.xip")]
    destination = "/Users/admin/Downloads/"
  }

  // iterate over all Xcode versions and install them
  // select the latest one as the default
  dynamic "provisioner" {
    for_each = local.xcode_install_provisioners
    labels = ["shell"]
    content {
      expect_disconnect = true
      inline = provisioner.value.inline
    }
  }

  provisioner "shell" {
    inline = [
      "source ~/.zprofile",
      "sudo xcodes select '${var.xcode_version[0]}'",
    ]
  }

  provisioner "shell" {
    inline = concat(
      ["source ~/.zprofile"],
      [
        for runtime in var.additional_runtimes : "sudo xcodes runtimes install ${runtime}"
      ]
    )
  }

  provisioner "shell" {
    expect_disconnect = true
    inline = [
      "source ~/.zprofile",
      "brew install libimobiledevice ideviceinstaller ios-deploy",
      "brew install xcbeautify",
      "brew install graphicsmagick imagemagick",
      "gem update",
      "gem uninstall --ignore-dependencies ffi && gem install ffi -- --enable-libffi-alloc"
    ]
  }

  # inspired by https://github.com/actions/runner-images/blob/fb3b6fd69957772c1596848e2daaec69eabca1bb/images/macos/provision/configuration/configure-machine.sh#L33-L61
  provisioner "shell" {
    inline = [
      "source ~/.zprofile",
      "curl -o AppleWWDRCAG3.cer https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer",
      "curl -o DeveloperIDG2CA.cer https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer",
      "curl -o add-certificate.swift https://raw.githubusercontent.com/actions/runner-images/fb3b6fd69957772c1596848e2daaec69eabca1bb/images/macos/provision/configuration/add-certificate.swift",
      "swiftc -suppress-warnings add-certificate.swift",
      "sudo ./add-certificate AppleWWDRCAG3.cer",
      "sudo ./add-certificate DeveloperIDG2CA.cer",
      "rm add-certificate* *.cer"
    ]
  }

  // check there is at least 15GB of free space and fail if not
  provisioner "shell" {
    inline = [
      "source ~/.zprofile",
      "df -h",
      "export FREE_MB=$(df -m | awk '{print $4}' | head -n 2 | tail -n 1)",
      "[[ $FREE_MB -gt ${var.disk_free_mb} ]] && echo OK || exit 1"
    ]
  }

  // some other health checks
  provisioner "shell" {
    inline = [
      "source ~/.zprofile",
      "test -d /Users/runner"
    ]
  }

  # Disable apsd[1][2] daemon as it causes high CPU usage after boot
  #
  # [1]: https://iboysoft.com/wiki/apsd-mac.html
  # [2]: https://discussions.apple.com/thread/4459153
  provisioner "shell" {
    inline = [
      "sudo launchctl unload -w /System/Library/LaunchDaemons/com.apple.apsd.plist"
    ]
  }

  # Compatibility with GitHub Actions Runner Images, where
  # /usr/local/bin belongs to the default user. Also see [2].
  #
  # [1]: https://github.com/actions/runner-images/blob/6bbddd20d76d61606bea5a0133c950cc44c370d3/images/macos/scripts/build/configure-machine.sh#L96
  # [2]: https://github.com/actions/runner-images/discussions/7607
  provisioner "shell" {
    inline = [
      "sudo chown admin /usr/local/bin"
    ]
  }

  # Wait for the "update_dyld_sim_shared_cache" process[1][2] to finish
  # to avoid wasting CPU cycles after boot
  #
  # [1]: https://apple.stackexchange.com/questions/412101/update-dyld-sim-shared-cache-is-taking-up-a-lot-of-memory
  # [2]: https://stackoverflow.com/a/68394101/9316533
  provisioner "shell" {
    inline = [
      "sleep 180"
    ]
  }
}
