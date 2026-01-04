
export interface Cell {
    lat: number;
    lng: number;
    val: number;
    tm?: number;
    p1?: number;
}

export interface CellWithZoom extends Cell {
    zoom: number;
}

// Represents a loaded SQLite database for a specific tile/area
export interface TileDB {
    id: string; // filename without extension, e.g., hm_14_35_139
    db: any; // SQL.Database
    zoom: number;
    baseLat: number;
    baseLng: number;
}

export interface MappingContextData {
    databases: Map<string, TileDB>;
    rawFiles: Map<string, ArrayBuffer>; // Non-sqlite files to preserve (imgs, etc)
    backupFileName: string; // Name of the inner .backup file
    fileName: string;
}
