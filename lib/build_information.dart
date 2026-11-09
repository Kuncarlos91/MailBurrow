// Supplied alongside Flutter's native version/build flags by release commands.
// An unstamped local build must not silently claim a different release identity.
const buildVersion = String.fromEnvironment('MAILSHELF_BUILD_VERSION');
const buildNumber = String.fromEnvironment('MAILSHELF_BUILD_NUMBER');
const buildInformation = buildVersion == ''
    ? 'Build information not supplied'
    : buildNumber == ''
    ? buildVersion
    : '$buildVersion (build $buildNumber)';
