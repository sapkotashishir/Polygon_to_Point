#! /bin/bash

export NSAMPLE=$1 # Number of sample per class in a scene.

# For Windows with OSGeo4W64 and Git Bash. Requiring "gdal-full" in OSGeo4W.
if [ "$OS" = 'Windows_NT' ]; then 
    export PYTHONPATH=/c/OSGeo4W64/apps/Python37/Lib
    export PATH=$PATH:/c/OSGeo4W64/bin
    export PATH=$PATH:`pwd`
    export GRASS=/c/OSGeo4W64/bin/grass78.bat
else
    export GRASS=grass
    export GRASS_EXEC=sh
fi

export WORKDIR=$(mktemp -d)
export OUTDB=$WORKDIR/tmp.sqlite
SCPDIR="SCP-shapefiles"

rm -f $OUTDB
SQL=$WORKDIR/tmp.sql
echo "DELETE FROM geometry_columns WHERE f_table_name = 'gt' OR  f_table_name = 'pt_gt'; DROP TABLE IF EXISTS gt; CREATE TABLE gt AS" > $SQL

for SHP in `find $SCPDIR -type f -regex ".*shp$" | sed 's/\.shp//g'`; do
    TBL=$(echo $(basename $SHP) | tr A-Z a-z | sed 's/-/_/g') # | sed 's/-.*//g'
    GID=$(echo $(basename $SHP) | sed -e "s/-/_/g") # s/\(S.\{24\}\).*/\1/g; 
    PROJ="$(cat $SHP.prj)"
    EPSG=$(python identifyEPSG.py "$PROJ")
    ogr2ogr -select MC_ID,C_ID,SCP_UID $WORKDIR/$(basename $SHP.shp) $SHP.shp
    spatialite -silent $OUTDB ".loadshp $WORKDIR/$(basename $SHP) $TBL UTF-8 $EPSG geometry"
    printf "SELECT ST_Transform(GEOMETRY,4326) as geometry,MC_ID as mc_id,'$GID' AS GID FROM ${TBL} UNION ALL " >> $SQL
done

echo "; INSERT INTO geometry_columns VALUES ('gt','geometry',3,2,4326,0);" >> $SQL
sed -i 's/UNION ALL ;/;/' $SQL
spatialite -silent $OUTDB < $SQL

#spatialite -silent $OUTDB ".loadshp 'past/Danworks' danworks UTF-8 32648 geometry"
spatialite -silent $OUTDB "INSERT INTO gt (geometry,mc_id) SELECT ST_Transform(geometry,4326), mc_id; SELECT CreateSpatialIndex('gt','geometry');"
#spatialite -silent $OUTDB "INSERT INTO gt (geometry,mc_id,gid) SELECT ST_Transform(geometry,4326), mc_id, gid from danworks; SELECT CreateSpatialIndex('gt','geometry');"

mkdir -p pointize
f_pointize() {
    export GID=$1
    make -C pointize -f $PWD/Makefile gt_${GID}_1.gpkg gt_${GID}_2.gpkg gt_${GID}_3.gpkg gt_${GID}_4.gpkg
}
export -f f_pointize

parallel --version
if [ $? -eq 0 ]; then
    parallel --bar f_pointize ::: `spatialite $OUTDB "SELECT gid from gt group by gid;"`
else 
    for GID in `spatialite $OUTDB "SELECT gid from gt group by gid;" | sed 's/\r//g'`; do 
        f_pointize $GID
    done
fi

rm -f gt-pt.*
for GPKG in pointize/*.gpkg ; do
    LAYER=$(ogrinfo $GPKG | grep Point | awk '{print $2}')
    GID=$(echo $LAYER | sed 's/gt_//g')
done
zip gt-pt.zip gt-pt.shp gt-pt.dbf gt-pt.shx gt-pt.prj
