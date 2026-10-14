clear; clc;

%% 1. Loading and preparing data

levels_data = readtimetable('../data/preprocessed/macro_levels_data.csv');
log_prices = levels_data;
log_prices{:,1:3} = log(levels_data{:,1:3});
monthly_diff_data = log_prices(2:end,:);

monthly_diff_data{:,1:3} = diff(log_prices{:,1:3}, 1, 1);
monthly_diff_data{:,4} = levels_data{2:end,4};

%% Simulation setup parameters

HORIZON = 1;  
trainFraction = 0.60;
p = 12;

numDraws = 20000;
baseSeed = 12345;

assert(HORIZON >= 1 && HORIZON <= 12 ...
    && HORIZON == floor(HORIZON));

%% Dati
TT = sortrows(monthly_diff_data);
dates = TT.Properties.RowTimes;
names = TT.Properties.VariableNames;
Y = TT{:,:};


[N,K] = size(Y);
assert(K == 4);

monthID = 12*year(dates) + month(dates);


nTrain = floor(trainFraction*N);

targets = (nTrain + 1 : N)';
origins = targets - HORIZON;
nForecasts = numel(targets);


%% Data Normalizing

firstOrigin = origins(1);

trainMean = mean(Y(1:firstOrigin,:), 1);
trainStd = std(Y(1:firstOrigin,:), 0, 1);

assert(all(trainStd > 0));

Z = (Y - trainMean) ./ trainStd;

fprintf('Prima origine: %s , Primo target: %s\n', ...
    char(string(dates(origins(1)))), ...
    char(string(dates(targets(1)))));
fprintf('Numero di previsioni: %d\n', nForecasts);


%% Conjugate Prioir

PriorMdl = bayesvarm(K, p, ...
    'ModelType', 'conjugate', ...
    'SeriesNames', string(names), ...
    'IncludeConstant', true, ...
    'IncludeTrend', false, ...
    'Center', zeros(K,1), ...
    'SelfLag', 0.20, ...
    'Decay', 2, ...
    'DoF', K + 2, ...
    'Omega', eye(K));

nRegressors = K*p + 1;


%% Results allocation for total inflation

monthlyForecast = zeros(nForecasts,1);

annualForecast = zeros(nForecasts,1);
annualLower80  = zeros(nForecasts,1);
annualUpper80  = zeros(nForecasts,1);
annualLower95  = zeros(nForecasts,1);
annualUpper95  = zeros(nForecasts,1);

annualActual = zeros(nForecasts,1);
annualMCSE = zeros(nForecasts,1);
elapsedSeconds = zeros(nForecasts,1);

for r = 1:nForecasts

    t = origins(r);
    target = targets(r);

    fprintf('Avvio origine %d/%d: %s\n', ...
        r, nForecasts, char(string(dates(t))));
    drawnow;
    timer = tic;

    %% 1. Posterior distribution
    Ztrain = Z(1:t,:);

    PosteriorMdl = estimate(PriorMdl, Ztrain);

    rng(baseSeed + t, 'twister');

    [CoeffDraws, SigmaDraws] = simulate( ...
        PosteriorMdl, 'NumDraws', numDraws);

    %% 2. Initial Regressor

    recent = Ztrain(end:-1:end-p+1,:);

    xInitial = [reshape(recent.', 1, K*p), 1];

    % Conserviamo il percorso dell'inflazione per ogni estrazione
    monthlyPaths = zeros(HORIZON, numDraws);

    for s = 1:numDraws

        % Ogni colonna di B contiene i coefficienti di un'equazione.
        B = reshape(CoeffDraws(:,s), nRegressors, K);

        % Se Sigma = L*L', un'innovazione riga è randn(1,K)*L'.
        L = chol(SigmaDraws(:,:,s), 'lower');
        innovations = randn(HORIZON,K) * L.';

        x = xInitial;

        for h = 1:HORIZON

            nextZ = x * B + innovations(h,:);

            % Prima variabile nelle unità originali: delta log HICP.
            monthlyPaths(h,s) = ...
                nextZ(1)*trainStd(1) + trainMean(1);

            % Aggiornamento con tutte le variabili simulate.
            x = [nextZ, x(1:K*(p-1)), 1];
        end
    end

    assert(all(isfinite(monthlyPaths(:))), ...
        'Traiettorie non finite: controllare il modello.');

    %% 3. Monthly forecast

    monthlyForecast(r) = mean(monthlyPaths(end,:));

    %% 4. Annual inflation reconstruction

    
    knownPart = sum(Y(target-11:t,1));

    annualDraws = knownPart + sum(monthlyPaths,1);

    annualForecast(r) = mean(annualDraws);

    bounds = quantile(annualDraws, [0.025 0.10 0.90 0.975]);

    annualLower95(r) = bounds(1);
    annualLower80(r) = bounds(2);
    annualUpper80(r) = bounds(3);
    annualUpper95(r) = bounds(4);

    annualMCSE(r) = std(annualDraws,0,2) / sqrt(numDraws);

    
    annualActual(r) = sum(Y(target-11:target,1));

    elapsedSeconds(r) = toc(timer);

    fprintf('Completata in %.2f secondi.\n', elapsedSeconds(r));
end



%% Saving data

BVARResults = table( ...
    dates(origins), dates(targets), ...
    Y(targets,1), monthlyForecast, ...
    annualActual, annualForecast, ...
    annualLower80, annualUpper80, ...
    annualLower95, annualUpper95, ...
    annualMCSE, elapsedSeconds, ...
    'VariableNames', { ...
    'Origin','Target', ...
    'MonthlyActual','MonthlyForecast', ...
    'AnnualLogActual','AnnualLogForecast', ...
    'Lower80','Upper80','Lower95','Upper95', ...
    'AnnualMCSE','Seconds'});

%% Metrics

errorAnnual = 100*(annualActual - annualForecast);

MAE = mean(abs(errorAnnual));
RMSE = sqrt(mean(errorAnnual.^2));

Coverage80 = mean( ...
    annualActual >= annualLower80 & annualActual <= annualUpper80);

Coverage95 = mean( ...
    annualActual >= annualLower95 & annualActual <= annualUpper95);

BVARMetrics = table(MAE, RMSE, Coverage80, Coverage95);
disp(BVARMetrics);

fprintf('Tempo totale: %.2f minuti\n', sum(elapsedSeconds)/60);

%% Data exportation

exportDir = fullfile(pwd, 'results');

if ~exist(exportDir, 'dir')
    mkdir(exportDir);
end

exportTable = BVARResults;


exportTable.Origin = string( ...
    exportTable.Origin, 'yyyy-MM-dd');
exportTable.Target = string( ...
    exportTable.Target, 'yyyy-MM-dd');


exportTable.Horizon = repmat(HORIZON, height(exportTable), 1);
exportTable.LagOrder = repmat(p, height(exportTable), 1);
exportTable.NumDraws = repmat(numDraws, height(exportTable), 1);

exportPath = fullfile( ...
    exportDir, sprintf('bvar_forecasts_h%d.csv', HORIZON));

writetable(exportTable, exportPath);

fprintf('Risultati salvati in:\n%s\n', exportPath);
