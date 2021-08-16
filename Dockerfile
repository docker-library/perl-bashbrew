FROM perl:5.28-slim

RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		ca-certificates \
		wget \
	; \
	rm -rf /var/lib/apt/lists/*

# https://github.com/docker-library/bashbrew/releases
ENV BASHBREW_VERSION 0.1.3
RUN set -eux; \
	wget -O /usr/local/bin/bashbrew-host-arch.sh "https://github.com/docker-library/bashbrew/raw/v${BASHBREW_VERSION}/scripts/bashbrew-host-arch.sh"; \
	chmod +x /usr/local/bin/bashbrew-host-arch.sh; \
	bashbrewArch="$(bashbrew-host-arch.sh)"; \
	wget -O /usr/local/bin/bashbrew "https://github.com/docker-library/bashbrew/releases/download/v${BASHBREW_VERSION}/bashbrew-$bashbrewArch"; \
	chmod +x /usr/local/bin/bashbrew; \
	bashbrew --version

# secure by default ♥ (thanks to sri!)
ENV PERL_CPANM_OPT --verbose --mirror https://cpan.metacpan.org
# TODO find a way to make --mirror-only / SSL work with backpan too :(
#RUN cpanm Digest::SHA Module::Signature
# TODO find a way to make --verify work with backpan as well :'(
#ENV PERL_CPANM_OPT $PERL_CPANM_OPT --verify

# reinstall cpanm itself, for good measure
RUN cpanm App::cpanminus

# useful for debugging
#  use via: perl -MCarp::Always script.pl ...
# https://metacpan.org/pod/Carp::Always
RUN cpanm Carp::Always

RUN set -eux; \
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		gcc \
		libc-dev \
		libssl-dev \
		zlib1g-dev \
	; \
	rm -rf /var/lib/apt/lists/*; \
	cpanm \
		EV \
		IO::Socket::IP \
		IO::Socket::Socks \
		Net::DNS::Native \
	; \
# the tests for IO::Socket::SSL like to hang... :(
	cpanm --notest IO::Socket::SSL; \
	apt-mark auto '.*' > /dev/null; \
	apt-mark manual $savedAptMark > /dev/null; \
	apt-get purge -y --auto-remove

# https://metacpan.org/pod/release/SRI/Mojolicious-8.21/lib/Mojo/IOLoop.pm#DESCRIPTION
ENV LIBEV_FLAGS 4
# epoll (Linux)

WORKDIR /opt/perl-bashbrew
COPY lib/Bashbrew.pm lib/
COPY Makefile.PL ./
RUN cpanm --installdeps .
COPY . .
RUN cpanm .

CMD ["./bin/put-multiarch.pl"]
