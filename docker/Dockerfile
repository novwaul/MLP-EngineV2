FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Seoul

# -----------------------------------------------------------------------------
# System deps
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    make \
    cmake \
    pkg-config \
    xz-utils \
    git \
    ca-certificates \
    curl \
    wget \
    # Verilator build deps
    python3 \
    python3-pip \
    python3-dev \
    autoconf \
    automake \
    libtool \
    flex \
    bison \
    help2man \
    perl \
    libfl-dev \
    zlib1g-dev \
    # Waveform
    gtkwave \
    # Convenience
    vim \
    less \
    sudo \
 && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Verilator (pinned version for reproducibility)
# -----------------------------------------------------------------------------
ARG VERILATOR_VERSION=v5.024
RUN git clone https://github.com/verilator/verilator /tmp/verilator \
 && cd /tmp/verilator \
 && git checkout ${VERILATOR_VERSION} \
 && autoconf \
 && ./configure --prefix=/usr/local \
 && make -j"$(nproc)" \
 && make install \
 && rm -rf /tmp/verilator

# -----------------------------------------------------------------------------
# SystemC (Accellera reference, built from source via CMake).
# Source: https://github.com/accellera-official/systemc (tagged release).
# -----------------------------------------------------------------------------
ARG SYSTEMC_VERSION=2.3.4
ENV SYSTEMC_HOME=/opt/systemc
RUN git clone --depth=1 --branch ${SYSTEMC_VERSION} \
        https://github.com/accellera-official/systemc.git /tmp/systemc \
 && cd /tmp/systemc \
 && mkdir build && cd build \
 && cmake -DCMAKE_INSTALL_PREFIX=${SYSTEMC_HOME} \
          -DCMAKE_CXX_STANDARD=17 \
          -DCMAKE_BUILD_TYPE=Release \
          -DBUILD_SHARED_LIBS=ON \
          .. \
 && cmake --build . -j"$(nproc)" \
 && cmake --install . \
 && ln -sf lib ${SYSTEMC_HOME}/lib-linux64 \
 && rm -rf /tmp/systemc

# -----------------------------------------------------------------------------
# UVM-SystemC (Accellera reference implementation).
# Source: https://github.com/accellera-official/uvm-systemc (tagged release).
# GitHub archives don't ship pre-generated `configure`, so autoreconf first.
# -----------------------------------------------------------------------------
ARG UVM_SYSTEMC_VERSION=1.0-beta5
ENV UVM_SYSTEMC_HOME=/opt/uvm-systemc
RUN git clone --depth=1 --branch ${UVM_SYSTEMC_VERSION} \
        https://github.com/accellera-official/uvm-systemc.git /tmp/uvm-systemc \
 && cd /tmp/uvm-systemc \
 && autoreconf -i \
 && mkdir build && cd build \
 && ../configure --prefix=${UVM_SYSTEMC_HOME} \
                 --with-systemc=${SYSTEMC_HOME} \
                 CXXFLAGS="-std=c++17 -O3" \
 && make -j"$(nproc)" \
 && make install \
 && rm -rf /tmp/uvm-systemc

# Make SystemC + UVM-SystemC discoverable at runtime / link time.
ENV LD_LIBRARY_PATH="${SYSTEMC_HOME}/lib:${SYSTEMC_HOME}/lib-linux64:${UVM_SYSTEMC_HOME}/lib:${LD_LIBRARY_PATH:-}"
ENV CPATH="${SYSTEMC_HOME}/include:${UVM_SYSTEMC_HOME}/include:${CPATH:-}"
ENV LIBRARY_PATH="${SYSTEMC_HOME}/lib:${SYSTEMC_HOME}/lib-linux64:${UVM_SYSTEMC_HOME}/lib:${LIBRARY_PATH:-}"

# -----------------------------------------------------------------------------
# RISC-V cross tool-chain
# -----------------------------------------------------------------------------
ARG RISCV_VERSION=14.2.0-3
RUN wget -q https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v${RISCV_VERSION}/xpack-riscv-none-elf-gcc-${RISCV_VERSION}-linux-x64.tar.gz \
    && tar -xzf xpack-riscv-none-elf-gcc-${RISCV_VERSION}-linux-x64.tar.gz -C /opt \
    && rm xpack-riscv-none-elf-gcc-${RISCV_VERSION}-linux-x64.tar.gz \
    && ln -s /opt/xpack-riscv-none-elf-gcc-${RISCV_VERSION} /opt/riscv

# Symbolic Link for Makefile which calls riscv32-unknown-elf-*
ENV PATH="/opt/riscv/bin:${PATH}"
RUN cd /opt/riscv/bin && \
    for f in riscv-none-elf-*; do \
        ln -sf "$f" "riscv32-unknown-elf-${f#riscv-none-elf-}"; \
    done

# -----------------------------------------------------------------------------
# Non-root user (matches host UID/GID at runtime via docker-compose)
# -----------------------------------------------------------------------------
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd --gid ${USER_GID} ${USERNAME} \
 && useradd --uid ${USER_UID} --gid ${USER_GID} -m ${USERNAME} \
 && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER ${USERNAME}
WORKDIR /workspace

CMD ["/bin/bash"]
