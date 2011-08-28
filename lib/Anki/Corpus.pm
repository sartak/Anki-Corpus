package Anki::Corpus;
use 5.14.0;
use warnings;
use utf8;
use Any::Moose;
use DBI;
use Params::Validate 'validate';

# ABSTRACT: interact with a corpus of sentences for Anki

has file => (
    is       => 'ro',
    isa      => 'Str',
    default  => sub { $ENV{ANKI_CORPUS} },
);

has dbh => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $self = shift;
        my $needs_schema = !-e $self->file;

        my $dbh = DBI->connect("dbi:SQLite:dbname=" . $self->file);
        $dbh->{sqlite_unicode} = 1;

        if ($needs_schema) {
            $self->schematize($dbh);
        }

        $dbh
    },
    handles => ['prepare'],
);

sub add_sentence {
    my $self = shift;
    my %args = validate(@_, {
        japanese    => { regex => qr/\p{Han}|\p{Hiragana}|\p{Katakana}/ },
        translation => { default => '' },
        readings    => { default => '' },
        source      => 1,
        suspended   => { default => 1, regex => qr/\A[01]\z/ },
        created     => { default => time },
        unsuspended => { default => undef },
        notes       => { default => undef },
    });

    if ($args{japanese} =~ s/。$//) {
        warn "Truncated 。 giving $args{japanese}\n";
    }

    warn "Length warning (" . length($args{japanese}) . "): $args{japanese}\n"
        if length($args{japanese}) > 500;

    if (!defined($args{unsuspended}) && !$args{suspended}) {
        $args{unsuspended} = time;
    }

    my $old_warn = $SIG{__WARN__} = sub { warn shift };
    local $SIG{__WARN__} = sub {
        my $warning = shift;
        $old_warn->($warning, @_) unless $warning =~ /column japanese is not unique/;
    };

    my $dbh = $self->dbh;
    $dbh->do("INSERT INTO sentences (japanese, translation, readings, source, suspended, created, unsuspended, notes) values (?, ?, ?, ?, ?, ?, ?, ?);", {},
        $args{japanese},
        $args{translation},
        $args{readings},
        $args{source},
        $args{suspended},
        $args{created},
        $args{unsuspended},
        $args{notes},
    );
}

sub schematize {
    my $self = shift;
    my $dbh = shift;

    $dbh->do(<< '    SCHEMA');
        CREATE TABLE sentences (
            japanese TEXT UNIQUE NOT NULL,
            translation TEXT,
            readings TEXT,
            source TEXT NOT NULL,
            suspended BOOLEAN,
            created INTEGER NOT NULL,
            unsuspended INTEGER,
            notes TEXT
        );
    SCHEMA
}

sub each_sentence {
    my $self  = shift;
    my $query = shift;
    my $sub   = shift;

    my $sth = $self->prepare("
        SELECT rowid, japanese, translation, readings, source, notes
        FROM sentences
        $query
    ;");
    $sth->execute;

    my $count = 0;
    while (my @results = $sth->fetchrow_array) {
        ++$count;
        $sub->(@results);
    }
    return $count;
}

sub print_each {
    my $self        = shift;
    my $query       = shift;
    my $filter      = shift;
    my $color_regex = shift || qr/(?!)/;

    my $count;

    $self->each_sentence($query, sub {
        return if $filter && !$filter->(@_);

        my ($id, $sentence, $translation, $readings, $source, $note) = @_;

        say "$id: $sentence" =~ s/$color_regex/\e[1;35m$&\e[m/gr;
        ++$count;

        for (["翻訳", $translation], ["読み", $readings], ["起こり", $source], ["Notes", $note]) {
            my ($field, $value) = @$_;
            next if !$value;
            $value =~ s/\n/\n        /g;
            say "    $field: $value" =~ s/$color_regex/\e[1;35m$&\e[m/gr;
        }

        say "";
    });

    if ($count) {
        print "$count row";
        print "s" if $count != 1;
        print "\n";
    }

    return $count;
}

1;

