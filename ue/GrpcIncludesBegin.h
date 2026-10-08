// Include before any gRPC / protobuf / abseil header, or generated *.pb.h /
// *.pb.cc file, inside an Unreal module. Always pair with GrpcIncludesEnd.h.
//
// Unreal defines check(expr) and verify(expr) macros. Abseil's btree (pulled in
// by every generated .pb.cc) declares a member function verify(), which the UE
// macro rewrites into garbage ("expected member name or ';'" in btree.h).
// These headers hide check/verify while third-party code is parsed and
// restore them afterwards.
//
// No include guard on purpose: the pair may be used several times per file.
THIRD_PARTY_INCLUDES_START
#pragma push_macro("check")
#pragma push_macro("verify")
#undef check
#undef verify
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
