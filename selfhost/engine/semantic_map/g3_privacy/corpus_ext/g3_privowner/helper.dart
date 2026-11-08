library corpus.helper;

/// A SECOND class also called `_Hidden`, in a different library. Two private
/// classes sharing a simple name must derive two distinct domains -- the same
/// property the two `_privateHelper` declarations prove for members, now for
/// an OWNER, since the owner is what the effective domain is read from.
class _Hidden {
  _Hidden(this.seed);

  final int seed;

  int ping() => seed + 10;
}

int helperAdd(int x) => x + 10;

int helperUsesHidden() => _Hidden(1).ping();
