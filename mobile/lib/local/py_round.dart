import 'dart:typed_data';

/// Rounds exactly like Python's built-in `round(x, digits)`.
///
/// The backend rounds every money figure with Python's `round`, which works on
/// the exact binary value of the float and breaks exact ties to the even
/// digit ("banker's rounding"): `round(0.125, 2) == 0.12`. Dart's
/// `toStringAsFixed` agrees except on exact ties, where it rounds away from
/// zero. This helper fixes that case so Dart results match the backend.
double pyRound(double x, [int digits = 0]) {
  if (x.isNaN || x.isInfinite || x == 0) return x;
  final fixed = x.toStringAsFixed(digits);
  final tie = _tieInfo(x, digits);
  if (tie == null) return double.parse(fixed);
  // Exact tie: choose the even neighbour. `tie` is floor(|x| * 10^digits).
  final lower = tie;
  final chosen = lower.isEven ? lower : lower + BigInt.one;
  final scaled = chosen.toString().padLeft(digits + 1, '0');
  final text = digits == 0 ? scaled : '${scaled.substring(0, scaled.length - digits)}.${scaled.substring(scaled.length - digits)}';
  final value = double.parse(text);
  return x < 0 ? -value : value;
}

/// If |x| * 10^digits is exactly halfway between two integers, returns the
/// lower integer; otherwise null. Uses exact integer arithmetic on the bits.
BigInt? _tieInfo(double x, int digits) {
  final bytes = ByteData(8)..setFloat64(0, x.abs());
  final bits = bytes.getUint64(0);
  final exponentBits = (bits >> 52) & 0x7FF;
  var mantissa = BigInt.from(bits & 0xFFFFFFFFFFFFF);
  int exponent;
  if (exponentBits == 0) {
    exponent = -1074; // subnormal
  } else {
    mantissa += BigInt.one << 52;
    exponent = exponentBits - 1075;
  }
  // |x| = mantissa * 2^exponent. Test if 2 * |x| * 10^digits is an odd integer.
  final scaled = mantissa * BigInt.from(10).pow(digits < 0 ? 0 : digits);
  final shift = -(exponent + 1);
  if (shift <= 0) return null; // 2*|x|*10^d is an even integer: no tie
  final divisor = BigInt.one << shift;
  if (scaled % divisor != BigInt.zero) return null;
  final doubled = scaled ~/ divisor; // = 2 * |x| * 10^digits
  if (doubled.isEven) return null;
  return (doubled - BigInt.one) ~/ BigInt.two;
}

/// Money is stored on the phone as whole minor units (paise, cents) so that
/// adding and subtracting never drifts. These convert at the edges.
int toMinor(num amount) => (amount * 100).round();
double fromMinor(int minor) => minor / 100;
