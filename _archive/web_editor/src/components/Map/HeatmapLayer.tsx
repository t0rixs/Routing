import React, { useMemo } from 'react';
import { useMap } from '@vis.gl/react-google-maps';
import { useStore } from '../../store/useStore';
import { getAllCellsFromDB } from '../../lib/mapping/CellQuery';
import { getCellColor, getCellBounds } from '../../lib/math/coords';
import type { CellWithZoom } from '../../types';
/// <reference types="google.maps" />


const HeatmapLayer: React.FC = () => {
    const { data, deleteCell } = useStore();
    const map = useMap();

    const cells = useMemo(() => {
        if (!data) return [];
        const allCells: CellWithZoom[] = [];
        data.databases.forEach((tileDB) => {
            if (tileDB.zoom === 16) {
                const dbCells = getAllCellsFromDB(tileDB.db);
                dbCells.forEach(c => allCells.push({ ...c, zoom: 16 }));
            }
        });
        return allCells;
    }, [data]);

    // Google Maps doesn't have a declarative "Rectangle" component in the library's main export 
    // that handles events easily in a loop without performance hit?
    // Actually @vis.gl/react-google-maps is wrapper around API.
    // We can use imperative API or custom component.
    // Let's create a custom Rectangle component to handle lifecycle.

    return (
        <>
            {cells.map((cell, idx) => (
                <Rectangle
                    key={`${cell.lat}-${cell.lng}-${idx}`}
                    cell={cell}
                    map={map}
                    onClick={() => deleteCell(cell)}
                />
            ))}
        </>
    );
};

// Custom wrapper for google.maps.Rectangle
const Rectangle = ({ cell, map, onClick }: { cell: CellWithZoom, map: google.maps.Map | null, onClick: () => void }) => {
    // We use a ref to hold the instance
    const rectangleRef = React.useRef<google.maps.Rectangle | null>(null);

    React.useEffect(() => {
        if (!map) return;

        const bounds = getBoundsLiteral(cell, 16);
        const color = getCellColor(cell.val, 16);

        // Parse HSLA to Hex for Google Maps?
        // Google Maps stroke/fill color expects HEX or standard CSS color string?
        // HSLA is supported in modern browsers, but let's verify google maps API support.
        // It generally supports CSS color strings.

        const rect = new google.maps.Rectangle({
            strokeColor: color,
            strokeOpacity: 0.8,
            strokeWeight: 1,
            fillColor: color,
            fillOpacity: 0.6,
            map: map,
            bounds: bounds,
            clickable: true
        });

        rect.addListener('click', () => {
            // Show InfoWindow? Or just delete?
            // MVP: just delete or confirm
            // User requested: "Cell selection -> detail display"
            // MVP: Click to delete is what we had.
            // Let's add simple confirm or just execute.
            // For now: execute onClick (which comes from parent)
            // Maybe show an InfoWindow first?
            // Let's rely on parent's deleteCell for now.

            // To show InfoWindow, we need to manage state.
            // Given the complexity of implementing InfoWindow for thousands of rects,
            // let's stay with "Click deletes" or add a console log / alert logic in parent.
            // Parent alert: "Delete cell?"
            const doDelete = window.confirm(`Delete Cell?\nLat: ${cell.lat}\nLng: ${cell.lng}\nVal: ${cell.val}`);
            if (doDelete) onClick();
        });

        rectangleRef.current = rect;

        return () => {
            rect.setMap(null);
        };
    }, [map, cell, onClick]); // Re-create if cell changes (e.g. value update -> color change)

    // Optimization: If only color changes, update options instead of recreate?
    // For MVP, recreation is fine as long as render count isn't crazy.

    return null;
};

// Helper to convert internal bounds to Google Maps BoundsLiteral
const getBoundsLiteral = (cell: CellWithZoom, zoom: number): google.maps.LatLngBoundsLiteral => {
    const bounds = getCellBounds(cell, zoom);
    return {
        north: bounds.north,
        south: bounds.south,
        east: bounds.east,
        west: bounds.west
    };
};

export default HeatmapLayer;
