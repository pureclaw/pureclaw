{ lib, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  pname = "wacli";
  version = "0.8.0";

  src = fetchFromGitHub {
    owner = "openclaw";
    repo = "wacli";
    rev = "v${version}";
    hash = "sha256-MS+QTG2UdhZYqPUmaU7bkCRchII1Ghd9/ojMMV9ZegA=";
  };

  vendorHash = "sha256-N5VIGCfMuaMbSuxwQLXUOCBGJ23WM4+3UA6vZhvxOPs=";

  subPackages = [ "cmd/wacli" ];

  # go-sqlite3 needs cgo; sqlite_fts5 enables FTS5 search per upstream README.
  env.CGO_ENABLED = "1";
  tags = [ "sqlite_fts5" ];

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
  ];

  doCheck = false;

  meta = {
    description = "WhatsApp CLI built on whatsmeow — sync, search, send";
    homepage = "https://wacli.sh";
    license = lib.licenses.mit;
    mainProgram = "wacli";
    platforms = lib.platforms.unix;
  };
}
