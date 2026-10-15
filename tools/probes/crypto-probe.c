/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include <windows.h>
#include <bcrypt.h>
#define SECURITY_WIN32
#include <security.h>
#include <schannel.h>
#include <stdio.h>

static int check(const WCHAR *algorithm, const char *label, ULONG bits, int rsa)
{
    BCRYPT_ALG_HANDLE provider = NULL;
    BCRYPT_KEY_HANDLE key = NULL;
    BCRYPT_PKCS1_PADDING_INFO padding = {BCRYPT_SHA256_ALGORITHM};
    BYTE hash[32] = {0}, signature[512];
    ULONG size = 0, flags = rsa ? BCRYPT_PAD_PKCS1 : 0;
    void *info = rsa ? &padding : NULL;
    NTSTATUS status;
    int ok = 0;

    status = BCryptOpenAlgorithmProvider(&provider, algorithm, NULL, 0);
    if (status) goto done;
    status = BCryptGenerateKeyPair(provider, &key, bits, 0);
    if (status) goto done;
    status = BCryptFinalizeKeyPair(key, 0);
    if (status) goto done;
    status = BCryptSignHash(key, info, hash, sizeof(hash), signature, sizeof(signature), &size, flags);
    if (status) goto done;
    status = BCryptVerifySignature(key, info, hash, sizeof(hash), signature, size, flags);
    if (status) goto done;
    signature[0] ^= 1;
    status = BCryptVerifySignature(key, info, hash, sizeof(hash), signature, size, flags);
    ok = status == (NTSTATUS)0xc000a000; /* STATUS_INVALID_SIGNATURE */
done:
    printf("%s key generation/sign/verify/reject-tampering: %s; status=%#lx\n", label, ok ? "PASS" : "FAIL", status);
    if (key) BCryptDestroyKey(key);
    if (provider) BCryptCloseAlgorithmProvider(provider, 0);
    return !ok;
}

int main(void)
{
    SCHANNEL_CRED credentials = {0};
    CredHandle handle;
    TimeStamp expiry;
    SECURITY_STATUS status;
    int failures = check(BCRYPT_ECDSA_P256_ALGORITHM, "ECDSA-P256", 256, 0);
    failures += check(BCRYPT_RSA_ALGORITHM, "RSA-2048", 2048, 1);
    credentials.dwVersion = SCHANNEL_CRED_VERSION;
    credentials.grbitEnabledProtocols = SP_PROT_TLS1_2_CLIENT;
    status = AcquireCredentialsHandleW(NULL, UNISP_NAME_W, SECPKG_CRED_OUTBOUND,
                                      NULL, &credentials, NULL, NULL, &handle, &expiry);
    printf("Schannel TLS 1.2 credentials: %s; status=%#lx\n", status ? "FAIL" : "PASS", status);
    if (!status) FreeCredentialsHandle(&handle);
    failures += !!status;
    return !!failures;
}
