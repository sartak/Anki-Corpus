package Anki::Corpus::Sentence;
use 5.14.0;
use warnings;
use utf8;
use Any::Moose;

has corpus => (
    is       => 'ro',
    isa      => 'Anki::Corpus',
    required => 1,
);

has rowid => (
    is       => 'ro',
    isa      => 'Int',
    required => 1,
);

has japanese => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has translation => (
    is        => 'ro',
    isa       => 'Str',
    predicate => 'has_translation',
);

has readings => (
    is        => 'ro',
    isa       => 'Str',
    predicate => 'has_readings',
);

has source => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has suspended => (
    is       => 'ro',
    isa      => 'Bool',
    required => 1,
);

has notes => (
    is      => 'ro',
    isa     => 'HashRef[Str]',
    lazy    => 1,
    builder => '_build_notes',
    clearer => '_clear_notes',
);

sub id { shift->rowid }

override BUILDARGS => sub {
    my $args = super;
    for ('translation', 'readings') {
        delete $args->{$_} if !defined($args->{$_}) || $args->{$_} eq '';
    }
    return $args;
};

sub _build_notes {
    my $self = shift;
    return { $self->corpus->notes_for($self->id) };
}

sub suspend {
    my $self = shift;
    $self->{suspended} = 1;
    $self->corpus->suspend_sentence($self->id);
}

sub unsuspend {
    my $self = shift;
    $self->{suspended} = 0;
    $self->corpus->unsuspend_sentence($self->id);
}

sub delete {
    my $self = shift;
    my $dbh = $self->corpus->dbh;
    $dbh->begin_work;

    $dbh->do("DELETE FROM sentences WHERE rowid=?;", {}, $self->rowid);
    $dbh->do("DELETE FROM notes WHERE sentence=?;", {}, $self->rowid);

    $dbh->commit;
}

sub refresh {
    my $self = shift;

    $self->_clear_notes;

    my $sth = $self->corpus->prepare("
        SELECT japanese, translation, readings, source, suspended
        FROM sentences
        WHERE rowid=?
    ;");
    $sth->execute($self->rowid);

    my @results = @{ $sth->fetchall_arrayref->[0] || [] }
        or return;

    $self->{japanese}    = $results[0];
    $self->{source}      = $results[3];
    $self->{suspended}   = $results[4];

    delete $self->{translation};
    $self->{translation} = $results[1]
        if defined $results[1] && $results[1] ne '';

    delete $self->{readings};
    $self->{readings} = $results[2]
        if defined $results[2] && $results[2] ne '';

    return $self;
}

no Any::Moose;
__PACKAGE__->meta->make_immutable;
1;
