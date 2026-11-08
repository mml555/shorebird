// Standalone driver for route_b_patch.cc. The engine's own shorebird_unittests
// target cannot link on this host (patch_cache.cc needs the private-fork
// Shorebird_ReadLinkHeader), so the taxonomy is exercised directly here against
// the REAL parser -- no copy of the logic.
#include "flutter/shell/common/shorebird/route_b_patch.h"
#include <cassert>
#include <cstdio>
#include <string>
#include <vector>
namespace fml { bool IsFile(const std::string&) { return false; } }
using namespace flutter::route_b;
static void U32(std::vector<uint8_t>* o, uint32_t v){for(int i=0;i<4;i++)o->push_back((v>>(8*i))&0xff);}
static std::vector<uint8_t> Build(const std::string& h, const std::string& p, uint32_t ver=1){
  std::vector<uint8_t> o; const char m[]={'S','B','R','B','P','T','C','H'};
  o.insert(o.end(),m,m+8); U32(&o,ver); U32(&o,(uint32_t)h.size());
  o.insert(o.end(),h.begin(),h.end()); o.insert(o.end(),p.begin(),p.end()); return o;
}
static const char* kHello="2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
static std::string Hdr(const std::string& id, const std::string& sha, size_t len){
  return std::string("{\"formatVersion\":1,\"release\":{\"buildId\":\"")+id+
    "\"},\"targets\":[{\"library\":\"package:a/a.dart\",\"selector\":\"greet\",\"offset\":0,\"length\":"+
    std::to_string(len)+",\"sha256\":\""+sha+"\"}]}";
}
static ContainerStatus P(const std::vector<uint8_t>& b, Container* c=nullptr){
  Container s; std::string e; return Parse(b.data(), b.size(), c?c:&s, &e);
}
static int fails=0;
#define CHECK(expr,label) do{ if(!(expr)){ printf("  FAIL %s\n",label); fails++; } else printf("  ok   %s\n",label);}while(0)
int main(){
  printf("route_b_patch taxonomy\n");
  CHECK(P(Build(Hdr("abc123",kHello,5),"hello"))==ContainerStatus::kOk, "sha256 known vector (hello) accepted");
  CHECK(P(Build(Hdr("abc123",std::string(64,'0'),5),"hello"))==ContainerStatus::kPayloadCorrupt, "wrong digest -> payload-corrupt");
  std::string vm="\x28\xb5\x2f\xfd not a container"; std::vector<uint8_t> v(vm.begin(),vm.end());
  CHECK(P(v)==ContainerStatus::kNotAContainer, "ordinary vmcode -> not-a-container");
  CHECK(P(std::vector<uint8_t>{'S','B','R'})==ContainerStatus::kNotAContainer, "too short -> not-a-container");
  CHECK(P(Build(Hdr("abc123",kHello,5),"hello",2))==ContainerStatus::kUnsupportedVersion, "version 2 -> unsupported-version");
  CHECK(P(Build("{not json","hello"))==ContainerStatus::kMalformed, "bad JSON -> malformed");
  CHECK(P(Build("{\"formatVersion\":1,\"targets\":[]}","hello"))==ContainerStatus::kMalformed, "no release.buildId -> malformed");
  CHECK(P(Build(Hdr("abc123",kHello,5000),"hello"))==ContainerStatus::kMalformed, "payload past EOF -> malformed");
  auto trunc=Build(Hdr("abc123",kHello,5),"hello"); trunc[12]=0xff; trunc[13]=0xff;
  CHECK(P(trunc)==ContainerStatus::kMalformed, "header past EOF -> malformed");
  CHECK(P(Build("{\"formatVersion\":1,\"release\":{\"buildId\":\"a\"},\"targets\":[]}","hello"))==ContainerStatus::kMalformed, "zero targets -> malformed");
  Container c; 
  CHECK(P(Build(Hdr("deadbeef",kHello,5),"hello"),&c)==ContainerStatus::kOk && c.release_build_id=="deadbeef"
        && c.targets.size()==1 && c.targets[0].selector=="greet"
        && std::string((const char*)c.targets[0].bytecode,c.targets[0].length)=="hello",
        "parses targets and exposes release id before targets are used");
  CHECK(SniffFile("/definitely/not/here/dlc.vmcode")==ContainerStatus::kNotAContainer, "missing file -> not-a-container");
  printf(fails? "TAXONOMY: %d FAILED\n" : "TAXONOMY: all passed\n", fails);
  return fails?1:0;
}
