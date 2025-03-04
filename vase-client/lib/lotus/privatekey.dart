import 'dart:typed_data';
import 'dart:math';

import 'package:pointycastle/key_generators/ec_key_generator.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/pointycastle.dart';
import 'package:pointycastle/random/fortuna_random.dart';

import 'address.dart';
import 'exceptions.dart';
import 'networks.dart';
import 'publickey.dart';
import 'encoding/base58check.dart' as bs58check;
import 'package:hex/hex.dart';
import 'encoding/utils.dart';

/// Manages an ECDSA private key.
///
/// Bitcoin uses ECDSA for it's public/private key cryptography.
/// Specifically it uses the `secp256k1` elliptic curve.
///
/// This class wraps cryptographic operations related to ECDSA from the
/// [PointyCastle](https:// pub.dev/packages/pointycastle) library/package.
///
/// You can read a good primer on Elliptic Curve Cryptography at [This Cloudflare blog post](https:// blog.cloudflare.com/a-relatively-easy-to-understand-primer-on-elliptic-curve-cryptography/)
///
///
class BCHPrivateKey {
  final _domainParams = ECDomainParameters('secp256k1');
  final _secureRandom = FortunaRandom();

  var _hasCompressedPubKey = false;
  NetworkType? _networkType = NetworkType.MAIN; // Mainnet by default

  var random = Random.secure();

  BigInt? _d;
  late ECPrivateKey _ecPrivateKey;
  BCHPublicKey? _BCHPublicKey;

  /// Constructs a  random private key.
  ///
  /// [networkType] - Optional network type. Defaults to mainnet. The network type is only
  /// used when serialising the Private Key in *WIF* format. See [toWIF()].
  ///
  BCHPrivateKey({networkType = NetworkType.MAIN}) {
    var keyParams = ECKeyGeneratorParameters(ECCurve_secp256k1());
    _secureRandom.seed(KeyParameter(_seed()));

    var generator = ECKeyGenerator();
    generator.init(ParametersWithRandom(keyParams, _secureRandom));

    var keypair = generator.generateKeyPair();

    _hasCompressedPubKey = true;
    _networkType = networkType;

    _ecPrivateKey = keypair.privateKey as ECPrivateKey;
    _d = _ecPrivateKey.d;
    _BCHPublicKey = BCHPublicKey.fromPrivateKey(this);
  }

  /// Constructs a  Private Key from a Big Integer.
  ///
  /// [privateKey] - The private key as a Big Integer value. Remember that in
  /// ECDSA we compute the public key (Q) as `Q = d * G`
  BCHPrivateKey.fromBigInt(BigInt privateKey,
      {NetworkType? networkType = NetworkType.MAIN}) {
    _ecPrivateKey = _privateKeyFromBigInt(privateKey);
    _d = privateKey;
    _hasCompressedPubKey = true;
    _networkType = networkType;
    _BCHPublicKey = BCHPublicKey.fromPrivateKey(this);
  }

  /// Construct a  Private Key from the hexadecimal value representing the
  /// BigInt value of (d) in ` Q = d * G `
  ///
  /// [privhex] - The BigInt representation of the private key as a hexadecimal string
  ///
  /// [networkType] - The network type we intend to use to corresponding WIF representation on.
  BCHPrivateKey.fromHex(String privhex, NetworkType networkType) {
    var d = BigInt.parse(privhex, radix: 16);

    _hasCompressedPubKey = true;
    _networkType = networkType;
    _ecPrivateKey = _privateKeyFromBigInt(d);
    _d = d;
    _BCHPublicKey = BCHPublicKey.fromPrivateKey(this);
  }

  /// Construct a  Private Key from the WIF encoded format.
  ///
  /// WIF is an abbreviation for Wallet Import Format. It is a format based on base58-encoding
  /// a private key so as to make it resistant to accidental user error in copying it. A wallet
  /// should be able to verify that the WIF format represents a valid private key.
  ///
  /// [wifKey] - The private key in WIF-encoded format. See [this bitcoin wiki entry](https:// en.bitcoin.it/wiki/Wallet_import_format)
  ///
  BCHPrivateKey.fromWIF(String wifKey) {
    if (wifKey.length != 51 && wifKey.length != 52) {
      throw InvalidKeyException(
          'Valid keys are either 51 or 52 bytes in length');
    }

    // decode from base58
    var versionAndDataBytes = bs58check.decodeChecked(wifKey);

    switch (wifKey[0]) {
      case '5':
        {
          if (wifKey.length != 51) {
            throw InvalidKeyException(
                'Uncompressed private keys have a length of 51 bytes');
          }

          _hasCompressedPubKey = false;
          _networkType = NetworkType.MAIN;
          break;
        }
      case '9':
        {
          if (wifKey.length != 51) {
            throw InvalidKeyException(
                'Uncompressed private keys have a length of 51 bytes');
          }

          _hasCompressedPubKey = false;
          _networkType = NetworkType.TEST;
          break;
        }
      case 'L':
      case 'K':
        {
          if (wifKey.length != 52) {
            throw InvalidKeyException(
                'Compressed private keys have a length of 52 bytes');
          }

          _networkType = NetworkType.MAIN;
          _hasCompressedPubKey = true;
          break;
        }
      case 'c':
        {
          if (wifKey.length != 52) {
            throw InvalidKeyException(
                'Compressed private keys have a length of 52 bytes');
          }

          _networkType = NetworkType.TEST;
          _hasCompressedPubKey = true;
          break;
        }
      default:
        {
          throw InvalidNetworkException(
              'Address WIF format must start with either [5] or [9]');
        }
    }

    // strip first byte
    var versionStripped =
        versionAndDataBytes.sublist(1, versionAndDataBytes.length);

    if (versionStripped.length == 33) {
      // drop last byte
      // throw error if last byte is not 0x01 to indicate compression
      if (versionStripped[32] != 0x01) {
        throw InvalidKeyException(
            'Compressed keys must have last byte set as 0x01. Yours is [${versionStripped[32]}]');
      }

      versionStripped = versionStripped.sublist(0, 32);
      _hasCompressedPubKey = true;
    } else {
      _hasCompressedPubKey = false;
    }

    var strippedHex =
        HEX.encode(versionStripped.map((elem) => elem.toUnsigned(8)).toList());

    var d = BigInt.parse(strippedHex, radix: 16);

    _ecPrivateKey = _privateKeyFromBigInt(d);
    _d = d;

    _BCHPublicKey = BCHPublicKey.fromPrivateKey(this);
  }

  /// Returns this Private Key in WIF format. See [toWIF()].
  String toWIF() {
    // convert private key _d to a hex string
    var wifKey = encodeUInt256(_d!).toList();
    if (wifKey[0] == 0) {}
    if (_networkType == NetworkType.MAIN) {
      wifKey = [0x80] + wifKey;
    } else if (_networkType == NetworkType.TEST ||
        _networkType == NetworkType.REGTEST) {
      wifKey = [0xef] + wifKey;
    }

    if (_hasCompressedPubKey) {
      wifKey.add(0x01);
    }

    var shaWif = sha256Twice(wifKey);
    var checksum = shaWif.sublist(0, 4);
    wifKey.addAll(checksum);
    var finalWif = bs58check.encode(wifKey);
    return finalWif;
  }

  /// Returns the *naked* private key Big Integer value as a hexadecimal string
  String toHex() {
    return _d!.toRadixString(16).padLeft(64, '0');
  }

  // convenience method to retrieve an address
  /// Convenience method that jumps through the hoops of generating and [Address] from this
  /// Private Key's corresponding [BCHPublicKey].
  Address toAddress({NetworkType? networkType = NetworkType.MAIN}) {
    return _BCHPublicKey!.toAddress(networkType: networkType ?? _networkType);
  }

  Uint8List _seed() {
    var random = Random.secure();
    var seed = List<int>.generate(32, (_) => random.nextInt(256));
    return Uint8List.fromList(seed);
  }

  ECPrivateKey _privateKeyFromBigInt(BigInt d) {
    if (d == BigInt.zero) {
      throw BadParameterException(
          'Zero is a bad value for a private key. Pick something else.');
    }

    return ECPrivateKey(d, _domainParams);
  }

  /// Returns the Network Type that we intend to use this private key on.
  /// This is also the value encoded in the WIF format representation of this key.
  NetworkType? get networkType {
    return _networkType;
  }

  /// Returns the *naked* private key Big Integer value as a Big Integer
  BigInt? get privateKey {
    return _d;
  }

  /// Returns the [BCHPublicKey] corresponding to this ECDSA private key.
  ///
  /// NOTE: `Q = d * G` where *Q* is the public key, *d* is the private key and `G` is the curve's Generator.
  BCHPublicKey? get publicKey {
    return _BCHPublicKey;
  }

  /// Returns true if the corresponding public key for this private key
  /// is in *compressed* format. To read more about compressed public keys see [BCHPublicKey().getEncoded()]
  bool get isCompressed {
    return _hasCompressedPubKey;
  }
}
