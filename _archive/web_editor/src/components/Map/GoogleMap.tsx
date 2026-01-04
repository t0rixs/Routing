import React, { useEffect } from 'react';
import { APIProvider, Map, useMap } from '@vis.gl/react-google-maps';
import { useStore } from '../../store/useStore';
import HeatmapLayer from './HeatmapLayer';

const API_KEY = import.meta.env.VITE_GOOGLE_MAPS_API_KEY || '';

// MapUpdater equivalent
const MapUpdater = () => {
    const { data } = useStore();
    const map = useMap();

    useEffect(() => {
        if (!map || !data || data.databases.size === 0) return;

        const firstDB = data.databases.values().next().value;
        if (firstDB) {
            const lat = firstDB.baseLat / 1000;
            const lng = firstDB.baseLng / 1000;
            map.setCenter({ lat, lng });
            map.setZoom(14);
        }
    }, [data, map]);

    return null;
};

const GoogleMapComponent: React.FC = () => {
    return (
        <APIProvider apiKey={API_KEY}>
            <div style={{ height: '100vh', width: '100%' }}>
                <Map
                    defaultCenter={{ lat: 35.6812, lng: 139.7671 }}
                    defaultZoom={13}
                    mapId="DEMO_MAP_ID" // Required for advanced markers/styles if needed
                    gestureHandling={'greedy'}
                    disableDefaultUI={false}
                >
                    <HeatmapLayer />
                    <MapUpdater />
                </Map>
            </div>
        </APIProvider>
    );
};

export default GoogleMapComponent;
