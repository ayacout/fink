#
# Fink::Engine class
#
# Fink - a package manager that downloads source and installs it
# Copyright (c) 2001 Christoph Pfisterer
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#

package Fink::Engine;

use Fink::Services qw(&prompt_boolean &print_breaking &print_breaking_prefix &latest_version);
use Fink::Package;
use Fink::PkgVersion;
use Fink::Config qw($basepath);
use Fink::Configure;
use Fink::Bootstrap;

use strict;
use warnings;

BEGIN {
  use Exporter ();
  our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
  $VERSION = 1.00;
  @ISA         = qw(Exporter);
  @EXPORT      = qw();
  @EXPORT_OK   = qw(&cmd_install);
  %EXPORT_TAGS = ( );   # eg: TAG => [ qw!name1 name2! ],
}
our @EXPORT_OK;

our %commands =
  ( 'rescan' => \&cmd_rescan,
    'configure' => \&cmd_configure,
    'bootstrap' => \&cmd_bootstrap,
    'fetch' => \&cmd_fetch,
    'build' => \&cmd_build,
    'install' => \&cmd_install,
    'enable' => \&cmd_activate,
    'activate' => \&cmd_activate,
    'use' => \&cmd_activate,
    'disable' => \&cmd_deactivate,
    'deactivate' => \&cmd_deactivate,
    'unuse' => \&cmd_deactivate,
    'update' => \&cmd_update,
    'update-all' => \&cmd_update_all,
    'fetch-all' => \&cmd_fetch_all,
    'fetch-missing' => \&cmd_fetch_missing,
  );

END { }       # module clean-up code here (global destructor)

### constructor using configuration

sub new_with_config {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $config_object = shift;

  my $self = {};
  bless($self, $class);

  $self->{config} = $config_object;

  $self->initialize();

  return $self;
}

### self-initialization

sub initialize {
  my $self = shift;
  my $config = $self->{config};
  my ($basepath);

  $self->{basepath} = $basepath = $config->param("basepath");
  if (!$basepath) {
    die "Basepath not set in config file!\n";
  }

  print "Reading package info...\n";
  Fink::Package->scan($basepath."/fink/info");

  if ($config->has_param("umask")) {
    umask oct($config->param("umask"));
  }
}

### process command

sub process {
  my $self = shift;
  my $cmd = shift;
  my ($cmdname, $proc);

  unless (defined $cmd) {
    print "NOP\n";
    return;
  }

  while (($cmdname, $proc) = each %commands) {
    if ($cmd eq $cmdname) {
      eval { &$proc(@_); };
      if ($@) {
	print "Failed: $@";
      } else {
	print "Done.\n";
      }
      return;
    }
  }

  die "unknown command: $cmd\n";
}

### the commands

sub cmd_rescan {
  print "Re-reading package info...\n";
  Fink::Package->forget_packages();
  Fink::Package->scan($basepath."/fink/info");
}

sub cmd_configure {
  Fink::Configure::configure();
}

sub cmd_bootstrap {
  Fink::Bootstrap::bootstrap();
}

sub cmd_fetch {
  my ($package, @plist);

  @plist = &expand_packages(@_);
  if ($#plist < 0) {
    die "no package specified for command 'fetch'!\n";
  }

  foreach $package (@plist) {
    $package->phase_fetch();
  }
}

sub cmd_fetch_all {
  my ($pname, $package, $version);

  foreach $pname (Fink::Package->list_packages()) {
    $package = Fink::Package->package_by_name($pname);
    $version = &latest_version($package->list_versions());
    $package->get_version($version)->phase_fetch();
  }
}

sub cmd_fetch_missing {
  my ($pname, $package, $version, $vo);

  foreach $pname (Fink::Package->list_packages()) {
    $package = Fink::Package->package_by_name($pname);
    $version = &latest_version($package->list_versions());
    $vo = $package->get_version($version);
    if (not $vo->is_fetched()) {
      $vo->phase_fetch();
    }
  }
}

sub cmd_activate {
  my ($package, @plist);

  @plist = &expand_packages(@_);
  if ($#plist < 0) {
    die "no package specified for command 'activate'!\n";
  }

  foreach $package (@plist) {
    $package->phase_activate();
  }
}

sub cmd_deactivate {
  my ($package, @plist);

  @plist = &expand_packages(@_);
  if ($#plist < 0) {
    die "no package specified for command 'deactivate'!\n";
  }

  foreach $package (@plist) {
    $package->phase_deactivate();
  }
}

sub cmd_build {
  &real_install(4, @_);
}

sub cmd_install {
  &real_install(0, @_);
}

sub cmd_update {
  &real_install(8, @_);
}

sub cmd_update_all {
  my (@plist, $pname, $package);

  foreach $pname (Fink::Package->list_packages()) {
    $package = Fink::Package->package_by_name($pname);
    if ($package->is_any_installed()) {
      push @plist, $pname;
    }
  }

  &real_install(8, @plist);
}

sub real_install {
  my $kind = shift;
  my ($pkgspec, $package, $pkgname, $item, $dep, $all_installed);
  my (%deps, @queue, @deplist, @vlist, @additionals);
  my ($oversion, $opackage, $v);
  my ($answer);

  %deps = ();

  # add requested packages
  foreach $pkgspec (@_) {
    # resolve package name
    #  (automatically gets the newest version)
    $package = Fink::PkgVersion->match_package($pkgspec);
    unless (defined $package) {
      die "no package found for specification '$pkgspec'!\n";
    }
    # no duplicates here
    #  (dependencies is different, but those are checked later)
    $pkgname = $package->get_name();
    if (exists $deps{$pkgname}) {
      print "Duplicate request for package '$pkgname' ignored.\n";
      next;
    }
    # skip if this version/revision is installed
    #  (also applies to update)
    next if $package->is_installed();
    # for build, also skip if present, but not installed
    next if ($kind == 4 and $package->is_present());
    # add to table
    $deps{$pkgname} = [ $pkgname, undef, $package, $kind | 1 ];
  }

  @queue = keys %deps;
  if ($#queue < 0) {
    print "No packages to install.\n";
    return;
  }

  # recursively expand dependencies
  while ($#queue >= 0) {
    $pkgname = shift @queue;
    $item = $deps{$pkgname};

    # if no Package object was assigned, find it
    if (not defined $item->[1]) {
      $item->[1] = Fink::Package->package_by_name($pkgname);
      if (not defined $item->[1]) {
	die "unknown package '$pkgname' in dependency list\n";
      }
    }

    # if no PkgVersion object was assigned, find one
    #  (either the installed version or the newest available)
    if (not defined $item->[2]) {
      $v = &latest_version($item->[1]->list_installed_versions());
      if (defined $v) {
	$item->[2] = $item->[1]->get_version($v);
      } else {
	$v = &latest_version($item->[1]->list_versions());
	if (defined $v) {
	  $item->[2] = $item->[1]->get_version($v);
	} else {
	  die "no version info available for '$pkgname'\n";
	}
      }
    }

    # check installation state
    if ($item->[2]->is_installed()) {
      $item->[3] |= 2;
      # already installed, don't think about it any more
      next;
    }

    # get list of dependencies
    @deplist = $item->[2]->get_depends();
    foreach $dep (@deplist) {
      if (exists $deps{$dep}) {
	# already in graph, just add link
	push @$item, $deps{$dep};
      } else {
	# create a node
	$deps{$dep} = [ $dep, undef, undef, 0 ];
	# add a link
	push @$item, $deps{$dep};
	# add to investigation queue
	push @queue, $dep;
      }
    }
  }

  # generate summary
  @additionals = ();
  foreach $pkgname (sort keys %deps) {
    $item = $deps{$pkgname};
    if ((($item->[3] & 1) == 0) and (($item->[3] & 2) == 0)) {
      push @additionals, $pkgname;
    }
  }

  # ask user when additional packages are to be installed
  if ($#additionals >= 0) {
    if ($#additionals > 0) {
      &print_breaking("The following ".scalar(@additionals).
		      " additional packages will be installed:");
    } else {
      &print_breaking("The following additional package ".
		      "will be installed:");
    }
    &print_breaking_prefix(join(" ",@additionals), 1, " ");
    $answer = &prompt_boolean("Do you want to continue?", 1);
    if (! $answer) {
      die "Dependencies not satisfied\n";
    }
  }

  # fetch all packages that need fetching
  foreach $pkgname (sort keys %deps) {
    $item = $deps{$pkgname};
    next if (($item->[3] & 2) == 2);   # already installed
    next if $item->[2]->is_fetched();
    $item->[2]->phase_fetch();
  }

  # install in correct order...
  while (1) {
    $all_installed = 1;
  PACKAGELOOP: foreach $pkgname (sort keys %deps) {
      $item = $deps{$pkgname};
      next if (($item->[3] & 2) == 2);   # already installed
      $all_installed = 0;

      # check dependencies
      foreach $dep (@$item[4..$#$item]) {
	next PACKAGELOOP if (($dep->[3] & 2) == 0);
      }

      # build it
      $package = $item->[2];

      $package->phase_unpack();
      $package->phase_patch();
      $package->phase_compile();
      $package->phase_install();
      $package->phase_build();

      if (($item->[3] & 4) == 0) {
	# check for installed version
	@vlist = $item->[1]->list_installed_versions();
	foreach $oversion (@vlist) {
	  if ($oversion ne $package->get_fullversion()) {
	    $opackage = $item->[1]->get_version($oversion);
	    $opackage->phase_deactivate();
	  }
	}

	$package->phase_activate();
      }

      # mark it as installed
      $item->[3] |= 2;
    }
    last if $all_installed;
  }
}

### helper routines

sub expand_packages {
  my ($pkgspec, $package, @package_list);

  @package_list = ();
  foreach $pkgspec (@_) {
    $package = Fink::PkgVersion->match_package($pkgspec);
    unless (defined $package) {
      die "no package found for specification '$pkgspec'!\n";
    }
    push @package_list, $package;
  }
  return @package_list;
}


### EOF
1;
