{ stdenv
, fetchurl
, autoPatchelfHook
, lib
, glibc
, bls ? ""
, blst ? ""
}:

stdenv.mkDerivation rec {
  pname = "prysm";
  version = "6.0.4";


  # Individual binary fetches
  beaconChain = fetchurl {
    url = "https://github.com/OffchainLabs/prysm/releases/download/v${version}/beacon-chain-v${version}-linux-amd64";
    sha256 = "sha256-W+daW1u4ZUQg6rohXxE4I2OV/n/GGCMpB5wo3FIXJY4=";
  };

  validator = fetchurl {
    url = "https://github.com/OffchainLabs/prysm/releases/download/v${version}/validator-v${version}-linux-amd64";
    sha256 = "sha256-2iPlAyByb0PlqkUc9tdWPtWh0NgGI3ml480Ql1wHG6Y=";
  };

  prysmctl = fetchurl {
    url = "https://github.com/OffchainLabs/prysm/releases/download/v${version}/prysmctl-v${version}-linux-amd64";
    sha256 = "sha256-ZLbiF0wdGKdpXXLbZLkP3RCYBhgzVKoqxpkCCwVYRa8=";
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ glibc ]; # may vary depending on what the binary needs

  dontUnpack = true;

  installPhase = ''
    mkdir -p $out/bin
    cp ${beaconChain} $out/bin/beacon-chain
    cp ${validator} $out/bin/validator
    cp ${prysmctl} $out/bin/prysmctl
    chmod +x $out/bin/*

  '';

  meta = with lib; {
    description = "Prysm beacon chain binary";
    homepage = "https://github.com/OffchainLabs/prysm";
    license = licenses.mit;
    platforms = platforms.linux;
    maintainers = [];
  };
}


# {
#   pkgs,
#   bls,
#   blst,
#   buildGoModule,
#   fetchFromGitHub,
#   libelf,
#   nix-update-script,
#   stdenv,
# }:
# # let c-kzg-4844 = pkgs.stdenv.mkDerivation rec {
# #         pname = "c-kzg-4844";
# #         version = "2.1.1";

# #         src = pkgs.fetchFromGitHub {
# #             owner = "ethereum";
# #             repo = "c-kzg-4844";
# #             rev = "v${version}";
# #             sha256 = "sha256-U7UwKhXrf3uEjvHaQgGS7NAUrtTrbsXYKIHKy/VYA7M="; # fill this in
# #         };

# #         nativeBuildInputs = [ pkgs.makeWrapper pkgs.gcc pkgs.git pkgs.go ];

# #         buildPhase = ''
# #             make go
# #         '';

# #         installPhase = ''
# #         mkdir -p $out/lib $out/include
# #         cp src/libckzg.a $out/lib/
# #         cp src/ckzg.h $out/include/
# #     '';
# #     };
# # in
# buildGoModule rec {
#   pname = "prysm";
#   version = "6.0.1";

#   src = fetchFromGitHub {
#     owner = "prysmaticlabs";
#     repo = pname;
#     rev = "v${version}";
#     hash = "sha256-H16YiHZa/flGXRretA+HqJZjPwDe8nFp770eMueM0e0=";
#   };

#   vendorHash = "sha256-oKT0pmV6Gt57ZeiIcu73QblBJ3uimEsuSTbAbC2W6jc=";

#   buildInputs = [bls blst libelf];

#   # preBuild = ''
#   #   # Navigate to the vendored c-kzg-4844 and bring in the C files
#   #   ckzgPath="vendor/github.com/ethereum/c-kzg-4844/v2"
#   #   cp ${fetchFromGitHub {
#   #     owner = "ethereum";
#   #     repo = "c-kzg-4844";
#   #     rev = "v2.1.1"; # or whatever commit hash/tag you need
#   #     sha256 = "sha256-U7UwKhXrf3uEjvHaQgGS7NAUrtTrbsXYKIHKy/VYA7M="; # fill this in
#   #   }}/src/ckzg.c $ckzgPath/bindings/go/
#   #   cp ${fetchFromGitHub {
#   #     owner = "ethereum";
#   #     repo = "c-kzg-4844";
#   #     rev = "v2.1.1";
#   #     sha256 = "sha256-U7UwKhXrf3uEjvHaQgGS7NAUrtTrbsXYKIHKy/VYA7M="; # fill this in
#   #   }}/src/ckzg.h $ckzgPath/bindings/go/
#   # '';

#   subPackages = [
#     "cmd/beacon-chain"
#     "cmd/client-stats"
#     "cmd/prysmctl"
#     "cmd/validator"
#   ];

#   doCheck = false;

#   ldflags = [
#     "-s"
#     "-w"
#     "-X github.com/prysmaticlabs/prysm/v4/runtime/version.gitTag=v${version}"
#   ];

#   env.CGO_ENABLED = true;

#   # CGO_CFLAGS = "-I${c-kzg-4844}/include";
#   # CGO_LDFLAGS = "-L${c-kzg-4844}/lib -lckzg";

#   passthru.updateScript = nix-update-script {};

#   meta = {
#     description = "Go implementation of Ethereum proof of stake";
#     homepage = "https://github.com/prysmaticlabs/prysm";
#     mainProgram = "beacon-chain";
#     platforms = ["x86_64-linux" "aarch64-linux"];
#   };
# }
