FROM openmicroscopy/omero-server:5.6.18

ARG BIOMERO_VERSION
ARG BIOMERO_IMPORTER_VERSION

USER root

## Default Python environment
ENV VIRTUAL_ENV=/opt/omero/server/venv3
ENV PATH=/opt/ice-3.6.5-0.3.0/bin:$VIRTUAL_ENV/bin/:$PATH
RUN echo 'skip_if_unavailable=True' >> /etc/dnf/dnf.conf
RUN yum -y install git

## Replace the default configuration files
COPY biomeroworker/ice.config biomeroworker/worker.cfg /opt/omero/server/OMERO.server/etc/templates/

## Install SSH client
RUN yum install -y openssh-clients
COPY biomeroworker/10-mount-ssh.sh /startup/10-mount-ssh.sh
RUN chmod +x /startup/10-mount-ssh.sh

## Install psycopg2 system prerequisites for postgres interaction
RUN yum install -y python3-devel postgresql-devel gcc
# Update PATH manually based on known locations
ENV PATH="/usr/pgsql-12/bin:/usr/pgsql-13/bin:/usr/pgsql-14/bin:/usr/pgsql-15/bin:/usr/pgsql-16/bin:/usr/bin:${PATH}"

## Setup OME ZARR & TIFF modules for data export
RUN yum install -y blosc-devel

# Sadly can't do this in Dockerfile:
# ENV JAVA_HOME=$(readlink -f /usr/bin/java | sed "s:/bin/java::")
ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk-11.0.23.0.9-3.el9.x86_64
RUN export JAVA_HOME

RUN wget https://github.com/glencoesoftware/bioformats2raw/releases/download/v0.12.0-rc1/bioformats2raw-0.12.0-rc1.zip \
    ; unzip -d /opt bioformats2raw-0.12.0-rc1.zip \
    && rm bioformats2raw-0.12.0-rc1.zip
ENV PATH="$PATH:/opt/bioformats2raw-0.12.0-rc1/bin"

## Add BIOMERO Omero Slurm Client
RUN yum -y install ack

# Install the importer first and BIOMERO second, in two separate pip runs.
#
# These two packages pin incompatible ezomero versions: biomero-importer wants
# ezomero==3.2.3 while biomero[full] wants ezomero==1.1.1. A single pip install
# fails outright with ResolutionImpossible, so the order here is deliberate and
# lets BIOMERO's pin win, leaving ezomero 1.1.1 installed.
#
# That is safe for the importer: it only calls ezomero.ezimport,
# ezomero.get_group_id and ezomero.post_map_annotation, all of which exist in
# 1.1.1, and it calls ezimport with keyword arguments, so the ln_s parameter
# that 3.x drops is not a positional-argument hazard. `pip check` therefore
# reports this as an unsatisfied requirement by design. The same tolerated
# mismatch exists in the previous known-good production image.
#
# Upstream resolves this in the 2.9 line, where biomero also moves to
# ezomero==3.2.3; revisit this block when adopting biomero 2.9.
#
# The old "force zarr < 3" reason for splitting the installs is obsolete:
# biomero-importer now requires zarr >= 3, biomero[full] pins zarr 3.1.5, and
# omero-cli-zarr 0.8.0 no longer constrains zarr.
RUN $VIRTUAL_ENV/bin/python -m pip install --upgrade pip \
    && $VIRTUAL_ENV/bin/python -m pip install biomero-importer==${BIOMERO_IMPORTER_VERSION} \
    && $VIRTUAL_ENV/bin/python -m pip install "biomero[full]==${BIOMERO_VERSION}"

# Apply small compatibility patches after installing BIOMERO.
# See patch_biomero_runtime.py for the Slurm/BIOMERO
# runtime issues this keeps reproducible across image rebuilds.
COPY biomeroworker/patch_biomero_runtime.py /tmp/patch_biomero_runtime.py
COPY biomeroworker/patches /tmp/patches
RUN $VIRTUAL_ENV/bin/python /tmp/patch_biomero_runtime.py

## Adjust processor code with BIOMERO Processor
# This version forwards HTTP(S) PROXY environment variables to the subprocesses (scripts)
# See latest OME version @ https://raw.githubusercontent.com/ome/omero-py/master/src/omero/processor.py
# Might need to merge important changes from time to time to keep this version compatible.
COPY biomeroworker/processor.py /opt/omero/server/venv3/lib/python3.11/site-packages/omero/

## Setup slurm-config for biomero
COPY biomeroworker/slurm-config.ini /etc/slurm-config.ini

## OMERO: Replace the default startup scripts
RUN rm /startup/60-database.sh
COPY biomeroworker/99-run.sh /startup/99-run.sh
RUN chmod +x /startup/99-run.sh
USER omero-server
