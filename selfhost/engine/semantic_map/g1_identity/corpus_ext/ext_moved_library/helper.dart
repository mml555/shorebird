library corpus.helper;

int helperAdd(int x) => x + 10;

int topLevel(int x) => x + 1;

/// Same simple name as app.dart's private helper, different privacy domain.
int _privateHelper(int x) => x * 3;

int helperUsesPrivate(int x) => _privateHelper(x);
