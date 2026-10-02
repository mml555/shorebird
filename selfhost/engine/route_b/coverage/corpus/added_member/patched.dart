@pragma('vm:never-inline')
String addedHelper() => 'helper';

@pragma('vm:never-inline')
String alpha() => addedHelper();

void main() => print(alpha());
