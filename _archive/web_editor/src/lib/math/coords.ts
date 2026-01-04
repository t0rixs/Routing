import { type Cell } from '../../types';

const BASE_LAT = -90;
const BASE_LNG = -180;

// Simple Bounds interface to replace Leaflet LatLngBounds
export interface SimpleBounds {
    north: number;
    south: number;
    east: number;
    west: number;
}

// Constants for cell size calculation
// Copied from logic/cellUni.dart: celltoLatLngBounds
export const getCellBounds = (cell: Cell, zoom: number): SimpleBounds => {
    const cellSizeDeg = 0.0002 * Math.pow(2, 14 - zoom);

    const lonWest = cell.lng * cellSizeDeg - 180.0;
    const lonEast = (cell.lng + 1) * cellSizeDeg - 180.0;

    const latSouth = cell.lat * cellSizeDeg - 90.0;
    const latNorth = (cell.lat + 1) * cellSizeDeg - 90.0;

    return {
        north: latNorth,
        south: latSouth,
        east: lonEast,
        west: lonWest
    };
};

export const getCellColor = (val: number, zoom: number): string => {
    // Logic from cellUni.dart: _calculateCellColor
    const max = Math.floor(14 * Math.pow(2, 14 - zoom));
    const normalized = Math.min(Math.max(val, 1), max) / max;

    const hue = (1 - normalized) * 240; // 240(Blue) -> 0(Red)

    return `hsla(${hue}, 100%, 50%, 0.6)`;
};

export const cellToLatLng = (cell: Cell | { lat: number, lng: number }, zoom: number): { lat: number, lng: number } => {
    const cellSizeDeg = 0.0002 * Math.pow(2, 14 - zoom);

    const latDeg = (cell.lat * cellSizeDeg) + BASE_LAT;
    const lngDeg = (cell.lng * cellSizeDeg) + BASE_LNG;

    // Return center of cell
    return { lat: latDeg + cellSizeDeg / 2, lng: lngDeg + cellSizeDeg / 2 };
};

export const latLngToCell = (lat: number, lng: number, zoom: number): { lat: number, lng: number } => {
    const cellSizeDeg = 0.0002 * Math.pow(2, 14 - zoom);

    const cellLat = Math.floor((lat - BASE_LAT) / cellSizeDeg);
    const cellLng = Math.floor((lng - BASE_LNG) / cellSizeDeg);

    return { lat: cellLat, lng: cellLng };
};
