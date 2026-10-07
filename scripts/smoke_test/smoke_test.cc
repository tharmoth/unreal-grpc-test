// Smoke test for the UE 5.3 gRPC build: starts an in-process server and makes
// one plaintext and one TLS round trip over localhost. The TLS case uses a
// self-signed certificate generated with UE's OpenSSL, so it checks that
// gRPC's TLS stack works against UE's OpenSSL 1.1.1t.

#include <chrono>
#include <cstdio>
#include <memory>
#include <string>

#include <grpcpp/grpcpp.h>
#include <openssl/evp.h>
#include <openssl/opensslv.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include "smoke.grpc.pb.h"

namespace {

class EchoService final : public smoke::Echo::Service {
  grpc::Status Say(grpc::ServerContext*, const smoke::EchoRequest* request,
                   smoke::EchoReply* reply) override {
    reply->set_text("echo: " + request->text());
    return grpc::Status::OK;
  }
};

struct KeyAndCert {
  std::string key_pem;
  std::string cert_pem;
};

std::string BioToString(BIO* bio) {
  char* data = nullptr;
  long len = BIO_get_mem_data(bio, &data);
  return std::string(data, static_cast<size_t>(len));
}

// Self-signed RSA-2048 certificate for "localhost".
bool MakeSelfSignedCert(KeyAndCert* out) {
  EVP_PKEY* pkey = EVP_PKEY_new();
  RSA* rsa = RSA_new();
  BIGNUM* e = BN_new();
  BN_set_word(e, RSA_F4);
  if (!RSA_generate_key_ex(rsa, 2048, e, nullptr)) return false;
  BN_free(e);
  EVP_PKEY_assign_RSA(pkey, rsa);

  X509* x509 = X509_new();
  ASN1_INTEGER_set(X509_get_serialNumber(x509), 1);
  X509_gmtime_adj(X509_getm_notBefore(x509), 0);
  X509_gmtime_adj(X509_getm_notAfter(x509), 3600);
  X509_set_pubkey(x509, pkey);
  X509_NAME* name = X509_get_subject_name(x509);
  X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
                             reinterpret_cast<const unsigned char*>("localhost"), -1, -1, 0);
  X509_set_issuer_name(x509, name);
  X509V3_CTX ctx;
  X509V3_set_ctx_nodb(&ctx);
  X509V3_set_ctx(&ctx, x509, x509, nullptr, nullptr, 0);
  X509_EXTENSION* san = X509V3_EXT_conf_nid(nullptr, &ctx, NID_subject_alt_name,
                                            const_cast<char*>("DNS:localhost"));
  X509_add_ext(x509, san, -1);
  X509_EXTENSION_free(san);
  if (!X509_sign(x509, pkey, EVP_sha256())) return false;

  BIO* key_bio = BIO_new(BIO_s_mem());
  BIO* cert_bio = BIO_new(BIO_s_mem());
  PEM_write_bio_PrivateKey(key_bio, pkey, nullptr, nullptr, 0, nullptr, nullptr);
  PEM_write_bio_X509(cert_bio, x509);
  out->key_pem = BioToString(key_bio);
  out->cert_pem = BioToString(cert_bio);
  BIO_free(key_bio);
  BIO_free(cert_bio);
  X509_free(x509);
  EVP_PKEY_free(pkey);
  return true;
}

bool Call(const std::shared_ptr<grpc::Channel>& channel, const char* label) {
  auto stub = smoke::Echo::NewStub(channel);
  smoke::EchoRequest request;
  request.set_text(label);
  smoke::EchoReply reply;
  grpc::ClientContext context;
  context.set_deadline(std::chrono::system_clock::now() + std::chrono::seconds(10));
  grpc::Status status = stub->Say(&context, request, &reply);
  if (!status.ok()) {
    std::fprintf(stderr, "    FAIL %s RPC: %d %s\n", label, status.error_code(),
                 status.error_message().c_str());
    return false;
  }
  std::printf("    OK %s RPC -> \"%s\"\n", label, reply.text().c_str());
  return reply.text() == std::string("echo: ") + label;
}

}  // namespace

int main() {
  std::printf("    gRPC %s, %s, C++%ld\n", grpc::Version().c_str(), OPENSSL_VERSION_TEXT,
              static_cast<long>(__cplusplus));

  KeyAndCert tls;
  if (!MakeSelfSignedCert(&tls)) {
    std::fprintf(stderr, "    FAIL could not create a test certificate\n");
    return 1;
  }

  EchoService service;
  int plain_port = 0;
  int tls_port = 0;
  grpc::SslServerCredentialsOptions ssl_opts;
  ssl_opts.pem_key_cert_pairs.push_back({tls.key_pem, tls.cert_pem});

  grpc::ServerBuilder builder;
  builder.AddListeningPort("127.0.0.1:0", grpc::InsecureServerCredentials(), &plain_port);
  builder.AddListeningPort("127.0.0.1:0", grpc::SslServerCredentials(ssl_opts), &tls_port);
  builder.RegisterService(&service);
  std::unique_ptr<grpc::Server> server = builder.BuildAndStart();
  if (!server || plain_port == 0 || tls_port == 0) {
    std::fprintf(stderr, "    FAIL server did not start\n");
    return 1;
  }

  bool ok = Call(grpc::CreateChannel("127.0.0.1:" + std::to_string(plain_port),
                                     grpc::InsecureChannelCredentials()),
                 "plaintext");

  grpc::SslCredentialsOptions client_opts;
  client_opts.pem_root_certs = tls.cert_pem;
  ok = Call(grpc::CreateChannel("localhost:" + std::to_string(tls_port),
                                grpc::SslCredentials(client_opts)),
            "tls") && ok;

  server->Shutdown();
  std::printf(ok ? "    Smoke test PASSED\n" : "    Smoke test FAILED\n");
  return ok ? 0 : 1;
}
