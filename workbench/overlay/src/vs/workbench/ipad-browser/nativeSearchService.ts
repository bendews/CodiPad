/*---------------------------------------------------------------------------------------------
 *  Copyright (c) CodiPad contributors. All rights reserved.
 *  Licensed under GPL-3.0-only. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { InstantiationType, registerSingleton } from '../../platform/instantiation/common/extensions.js';
import { ISearchService } from '../services/search/common/search.js';
import { SearchService } from '../services/search/common/searchService.js';

// Native file: providers have no browser FileSystemHandle. Wait for MainThreadSearch to register
// NativeExtHostSearch's upstream ripgrep providers, including after a host restart. The common
// service retains open-editor results, cancellation, provider routing and URI identity handling.
registerSingleton(ISearchService, SearchService, InstantiationType.Delayed);
