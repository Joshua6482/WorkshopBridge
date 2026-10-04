{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  packages = with pkgs; [
    lua
    gradle
    zulu25
    openssl_3_5
  ];

  shellHook = ''
    export JAVA_HOME="${pkgs.zulu25}"
    export PATH="$JAVA_HOME/bin:$PATH"
  '';
}
