#!/usr/bin/env bash

# ZONA DE CONSTANTES
# ==================
KVMDOM='practicalxc'
UsuarioPG='hlc'

IPLXC='10.10.5.2'
IPKVM='10.10.5.3'

VersionPG='9.4'
ClusterPG='hlc'
BaseDir='postgresql'
ClusterPath="/home/${UsuarioPG}/${BaseDir}"

VOLUMENLOGICO='/dev/debvg1/dataPG'

SSHCMD='ssh -q -o BatchMode=yes'

TARGETDVC='vdb'

EXTIFACE='br0'
EXTPORT=5432
INTPORT=5433

function Salida {
    printf 'Saliendo del script..\n'
    exit
}
trap Salida EXIT INT TERM

function ComprobarKVM(){
    printf 'Comprobando estado de la máquina KVM...\n'
    if [[ $(virsh dominfo $KVMDOM | grep -Ei '.*state:[[:space:]]*running.*') ]]; then
        printf 'Máquina encendida..\n'
    else
        printf 'Máquina apagada.. Encendiendo..\n'
        maxintentos=3
        intento=0
        while (( intento < maxintentos )) && [[ ! $(virsh dominfo $KVMDOM | grep -Ei '.*state:[[:space:]]*running.*') ]]; do
            ((intento++))
            printf "Intentando arrancar la máquina KVM (${intento}/${maxintentos})...\n"
            virsh start $KVMDOM
            [[ ! $(virsh dominfo $KVMDOM | grep -Ei '.*state:[[:space:]]*running.*') ]] && sleep 5
        done
        [[ ! $(virsh dominfo $KVMDOM | grep -Ei '.*state:[[:space:]]*running.*') ]] && \
            printf 'Error iniciando la máquina KVM...\n' && \
            exit 1
    fi
}

function ComprobarCreds(){
    printf 'Comprobando credenciales SSH\n'
    error=0
    for HOSTCHK in $IPLXC $IPKVM; do
        for USERCHK in root $UsuarioPG; do
            $SSHCMD ${USERCHK}@${HOSTCHK} exit
            STATUS=$?
            (( STATUS != 0 )) && \
                printf "Error en $HOSTCHK con usuario: $USERCHK\n" && \
                printf "Estado: $STATUS\n" && \
                error=1
        done
    done
    (( error == 1 )) && \
        printf 'Comprueba las credenciales antes de ejecutar el script...\n' && \
        exit 1
    printf 'Credenciales comprobadas con éxito.\n'
}

function PararCluster(){
    printf 'Parando el clúster...'
    $SSHCMD ${UsuarioPG}@${IPLXC} pg_ctlcluster -m fast ${VersionPG} ${ClusterPG} stop &>/dev/null
    exito=$?
    (( exito != 0 )) && \
        printf 'No se puede parar el cluster en LXC...\nNo se desmonta el volumen.\n' && \
        exit 1
    printf 'Cluster parado.\n'
}

function DesmontarVolumen(){
    printf 'Desmontando el volumen..\n'
    $SSHCMD root@${IPLXC} umount $ClusterPath &>/dev/null
    exito=$?
    (( exito != 0 )) && \
        printf 'No se puede desmontar el volumen.. No se conecta a KVM\n' && \
        exit 1
    printf 'Volumen desmontado con éxito.\n'
}

function ConectarVolumen(){
    printf 'Conectando disco a KVM...\n'
    virsh attach-disk $KVMDOM \
        --source $VOLUMENLOGICO \
        --target $TARGETDVC \
        --targetbus virtio \
        --driver qemu \
        --subdriver raw \
        --cache none \
        --sourcetype block \
        --live
    (( $? != 0 )) && \
        printf 'No se pudo conectar el volumen.. No se sigue con el script\n' && \
        exit 1
    printf 'Disco conectado con éxito.\n'
}

function MontarDispositivo(){
    printf 'Montando unidad en vdb...\n'
    $SSHCMD root@${IPKVM} mount /dev/${TARGETDVC} ${ClusterPath} &>/dev/null
    (( $? != 0 )) && \
        printf 'No se pudo montar el disco.. No se sigue con el script\n' && \
        exit 1
    printf 'Unidad montada con éxito.\n'
}

function IniciarCluster(){
    printf 'Iniciando clúster en KVM...\n'
    $SSHCMD ${UsuarioPG}@${IPKVM} pg_ctlcluster ${VersionPG} ${ClusterPG} start &>/dev/null
    (( $? != 0 )) && \
        printf 'No se pudo iniciar el clúster.. No se sigue con el script\n' && \
        exit 1
    printf 'Cluster iniciado con éxito.\n'
}

function CrearReglasIpTables(){
    printf 'Creando reglas DNAT de IPTABLES...\n'
    iptables -t nat -D PREROUTING -p tcp --dport ${EXTPORT} -i ${EXTIFACE} -j DNAT --to ${IPLXC}:${INTPORT}
    iptables -t nat -A PREROUTING -p tcp --dport ${EXTPORT} -i ${EXTIFACE} -j DNAT --to ${IPKVM}:${INTPORT}
}

if [[ -z $1 ]]; then
    ComprobarKVM
    ComprobarCreds
    PararCluster
    DesmontarVolumen
    ConectarVolumen
    MontarDispositivo
    IniciarCluster
    CrearReglasIpTables
elif [[ $1 == '--help' ]]; then
    printf 'ComprobarKVM\n'
    printf 'ComprobarCreds\n'
    printf 'PararCluster\n'
    printf 'DesmontarVolumen\n'
    printf 'ConectarVolumen\n'
    printf 'MontarDispositivo\n'
    printf 'IniciarCluster\n'
    printf 'CrearReglasIpTables\n'
else
    if [[ $2 == '-d' ]]; then
        printf 'Modo depuración\n'
        set -x
        $1
        set +x
    else
        $1
    fi
fi
