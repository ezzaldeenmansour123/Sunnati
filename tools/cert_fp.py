#!/usr/bin/env python3
"""Extract the signing-certificate SHA-256 fingerprint from an APK's
APK Signing Block v2/v3 (no Java/keytool needed).

Usage: python3 cert_fp.py <apk-file>
Prints the SHA-256 fingerprint(s) of the signer certificate(s).
"""
import hashlib
import struct
import sys
import zipfile

# APK signing block magic
MAGIC = b"APK Sig Block 42"
# Signer block IDs: 0x7109871a = v2, 0x7172571a = v3, 0x1b93ad61 = v3.1
SIGNER_IDS = {0x7109871A, 0x7172571A, 0x1B93AD61}


def find_signing_block(data: bytes):
    """Return (block_start, block_bytes) of the APK Signing Block."""
    # EOCD is the last 22 bytes (plus optional comment); find it.
    eocd_off = data.rfind(b"PK\x05\x06")
    if eocd_off < 0:
        raise ValueError("EOCD not found")
    cd_offset = struct.unpack_from("<I", data, eocd_off + 16)[0]
    # Signing block footer: 8-byte size + 16-byte magic, right before CD.
    footer_off = cd_offset - 24
    size = struct.unpack_from("<Q", data, footer_off)[0]
    magic = data[footer_off + 8:footer_off + 24]
    if magic != MAGIC:
        raise ValueError("APK Signing Block magic not found")
    block_start = cd_offset - size - 8
    return block_start, data[block_start:cd_offset]


def parse_signers(block: bytes):
    """Yield (block_id, signer_cert_der_bytes) for each signer in v2/v3 blocks."""
    # block layout: size(8) | pairs... | size(8) | magic(16)
    # pairs: len(8) | id(4) | value(len-4)
    pos = 8
    end = len(block) - 24
    while pos < end:
        pair_len = struct.unpack_from("<Q", block, pos)[0]
        pair_id = struct.unpack_from("<I", block, pos + 8)[0]
        value = block[pos + 12:pos + 8 + pair_len]
        if pair_id in SIGNER_IDS:
            yield pair_id, value
        pos += 8 + pair_len


def parse_v2_signers(value: bytes):
    """v2 block value: sequence of signers; each signer has a cert list.
    Returns list of cert DER bytes."""
    certs = []
    pos = 0
    # signer: length-prefixed; inside: signed_data_len, signed_data,
    # public_key_len, public_key, then... actually v2 signer:
    #   length(4) | signed_data | ... — we walk length-prefixed fields.
    # Simpler: scan for the certs: signer contains
    #   signed_data (len-prefixed) -> digests, certs (len-prefixed sequence
    #   of len-prefixed certs), additional_attrs.
    # We parse: signer_len(4), then inside:
    #   signed_data_len(4), signed_data, public_key_len(4), public_key
    # and signed_data contains: digests_len(4), digests, certs_len(4),
    # certs (each len-prefixed), additional_attrs_len(4), attrs.
    n = len(value)
    while pos + 4 <= n:
        signer_len = struct.unpack_from("<I", value, pos)[0]
        if signer_len == 0 or pos + 4 + signer_len > n:
            break
        signer = value[pos + 4:pos + 4 + signer_len]
        pos += 4 + signer_len
        # inside signer: signed_data_len(4) | signed_data | ...
        if len(signer) < 4:
            continue
        sd_len = struct.unpack_from("<I", signer, 0)[0]
        sd = signer[4:4 + sd_len]
        if len(sd) < 4:
            continue
        # signed_data: digests_len(4) | digests | certs_len(4) | certs...
        d_len = struct.unpack_from("<I", sd, 0)[0]
        off = 4 + d_len
        if off + 4 > len(sd):
            continue
        c_len = struct.unpack_from("<I", sd, off)[0]
        off += 4
        certs_end = off + c_len
        while off + 4 <= certs_end:
            cl = struct.unpack_from("<I", sd, off)[0]
            certs.append(sd[off + 4:off + 4 + cl])
            off += 4 + cl
    return certs


def parse_v3_signers(value: bytes):
    """v3 block value: sequence of signers; each signer:
    length(4) | signed_data_len(4) | signed_data | min_sdk(4) | max_sdk(4)
    | public_key_len(4) | public_key.
    signed_data: digests_len(4) | digests | certs_len(4) | certs..."""
    certs = []
    pos = 0
    n = len(value)
    while pos + 4 <= n:
        signer_len = struct.unpack_from("<I", value, pos)[0]
        if signer_len == 0 or pos + 4 + signer_len > n:
            break
        signer = value[pos + 4:pos + 4 + signer_len]
        pos += 4 + signer_len
        if len(signer) < 4:
            continue
        sd_len = struct.unpack_from("<I", signer, 0)[0]
        sd = signer[4:4 + sd_len]
        if len(sd) < 4:
            continue
        d_len = struct.unpack_from("<I", sd, 0)[0]
        off = 4 + d_len
        if off + 4 > len(sd):
            continue
        c_len = struct.unpack_from("<I", sd, off)[0]
        off += 4
        certs_end = off + c_len
        while off + 4 <= certs_end:
            cl = struct.unpack_from("<I", sd, off)[0]
            certs.append(sd[off + 4:off + 4 + cl])
            off += 4 + cl
    return certs


def main():
    apk = sys.argv[1]
    with open(apk, "rb") as f:
        data = f.read()
    try:
        _, block = find_signing_block(data)
    except ValueError as e:
        print(f"no signing block: {e}")
        return 1
    found = False
    for block_id, value in parse_signers(block):
        if block_id == 0x7109871A:
            certs = parse_v2_signers(value)
            label = "v2"
        else:
            certs = parse_v3_signers(value)
            label = "v3/v3.1"
        for cert in certs:
            fp = hashlib.sha256(cert).hexdigest().upper()
            print(f"{label} cert SHA-256: {':'.join(fp[i:i+2] for i in range(0, 64, 2))}")
            found = True
    if not found:
        print("no signer certificates found in signing block")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
