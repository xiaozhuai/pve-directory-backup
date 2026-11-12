PERL_DIR ?= /usr/share/perl5
DESTDIR ?=

.PHONY: check-pve install

# Run on the target PVE host, using its real dependencies.
check-pve:
	perl -MPVE::Storage -MPVE::BackupProvider::Plugin::Base -e 'print "PVE backup provider API available\n"'
	perl -Isrc -c src/PVE/BackupProvider/Plugin/Directory.pm
	perl -Isrc -c src/PVE/Storage/Custom/BackupProviderDirPlugin.pm

install:
	install -d "$(DESTDIR)$(PERL_DIR)/PVE/BackupProvider/Plugin" "$(DESTDIR)$(PERL_DIR)/PVE/Storage/Custom"
	install -m 0644 src/PVE/BackupProvider/Plugin/Directory.pm "$(DESTDIR)$(PERL_DIR)/PVE/BackupProvider/Plugin/Directory.pm"
	install -m 0644 src/PVE/Storage/Custom/BackupProviderDirPlugin.pm "$(DESTDIR)$(PERL_DIR)/PVE/Storage/Custom/BackupProviderDirPlugin.pm"
