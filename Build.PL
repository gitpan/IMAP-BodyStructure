use Module::Build;

my $build = Module::Build->new(
    module_name => 'IMAP::BodyStructure',
    license     => 'artistic',
    dist_version_from => 'lib/IMAP/BodyStructure.pm',
);

$build->create_build_script;
