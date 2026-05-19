{ ... }:
{
  users.users.mboehme = {
    isNormalUsers = true;
    description = "Mika Boehme";
    extraGroups = [
      "wheel"
      "video"
      "audio"
      "input"
      "networkmanager"
      "kvm"
      "dialout"
    ];
    shell = null;
    initialHashedPassword = "REPLACE_ME";
  };
}