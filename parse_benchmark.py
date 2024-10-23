import pandas as pd
import matplotlib.pyplot as plt
import sys
import signal
import numpy as np
signal.signal(signal.SIGINT, signal.SIG_DFL)
plt.style.use('ggplot')
# the filename must look like <test_phase>_<metric>_results.csv
"""
valid test phase names:
- deployment
- pod
- deployment-pods
- deployment-containers
- idle
"""
if len(sys.argv) != 2:
    print("Usage: python parse_benchmark.py <path_to_csv>")
    print("Example: python parse_benchmark.py /path/to/pod_memory_results.csv")
    sys.exit(1)

color_configs = {
    '1': {
        'color1': '#66a61e',
        'color2': '#e6ab02',
        'color3': '#e7298a'
    },
    '2': {
        'color1': '#1b9e77',
        'color2': '#d95f02',
        'color3': '#7570b3'
    },
    '4': {
        'color1': '#a6761d',
        'color2': '#666666',
        'color3': '#86BBD8'
    }
}

# we can parse the metric and test phase from the file name
file_path = sys.argv[1]
filename = file_path.split('/')[-1].split('_')
# the last element should be "results.csv"
# second last should be the metric
# third last should be the test phase
results_csv = filename[-1]
if results_csv != 'results.csv':
    print("Invalid file. Must end with results.csv")
    sys.exit(1)
metric = filename[-2]
if metric not in ['memory', 'cpu', 'api']:
    print("Invalid metric in file name. File name must look like <test_phase>_<metric>_results.csv")
    sys.exit(1)
test_phase = filename[-3]
if test_phase not in ['idle', 'deployment', 'pod', 'deployment-pods', 'deployment-containers', 'rate-limiters']:
    print("Invalid test phase in file name. File name must look like <test_phase>_<metric>_results.csv")
    sys.exit(1)

cpu_memory_columns = ['Operator', 'Admission', 'Recommender', 'Updater']
api_columns = ['APIPerformance', 'Webhook', 'RequestLatency']

df = pd.read_csv(file_path, sep=";", index_col=False)

if metric == 'cpu':
    for column in cpu_memory_columns:
        df[column] = df[column].apply(lambda x: float(x.replace('m', '').strip()))
elif metric == 'memory':
    for column in cpu_memory_columns:
	    df[column] = df[column].apply(lambda x: float(x.replace('MiB', '').strip()))
elif metric == 'api':
    for column in api_columns:
        if column == 'APIPerformance':
            df[column] = df[column].apply(lambda x: float(x.replace('req/s', '').strip()))
        elif column == 'Webhook' or column == 'RequestLatency':
            df[column] = df[column].apply(lambda x: float(x.replace('ms/req', '').strip()))
        else:
            print(f"Invalid column {column}")
            sys.exit(1)

# handle rate limiting phase separately
if test_phase == 'rate-limiters':
    df['Step'] = df['Step'].apply(lambda x: x.replace('64 deployments ', ''))
    if metric == 'cpu' or metric == 'memory':
        plt.plot(df['Step'], df['Admission'], label='Admission', marker='x')
        plt.plot(df['Step'], df['Recommender'], label='Recommender', marker='s')
        plt.plot(df['Step'], df['Updater'], label='Updater', marker='d')
        if metric == 'cpu':
            test_phase_title='CPU Usage Over REPLACE_ME (m) (interpolated)'
            plt.ylabel('CPU Usage (m)')
        elif metric == 'memory':
            test_phase_title='Memory Usage Over REPLACE_ME (MiB) (interpolated)'
            plt.ylabel('Memory Usage (MiB)')
    elif metric == 'api':
        plt.plot(df['Step'], df['APIPerformance'], label='API Performance (req/s)', marker='o')
        plt.plot(df['Step'], df['Webhook'], label='Webhook (ms/req)', marker='x')
        plt.plot(df['Step'], df['RequestLatency'], label='API Request Latency (ms)', marker='s')

        test_phase_title='API Performance Over REPLACE_ME (interpolated)'
        plt.ylabel('API Performance')
    plt.xticks(range(0, len(df['Step'])), labels=df['Step'], rotation=45)
    # plt.ylim(0, 80) turn on if you want to focus on the latencies
    plt.tight_layout()
    plt.legend()
    plt.title('Rate Limiter Configurations testing ' +  metric)
    plt.show()
    sys.exit(0)

original_steps = df['Step'].copy(deep=True)
if test_phase == 'deployment-pods' or test_phase == 'deployment-containers':
    df['Step'] = df['Step'].apply(lambda x: x.split(' ')[0])
    # separate into 3 equal parts
    first_df = df.iloc[:int(len(df)/3)]
    second_df = df.iloc[int(len(df)/3):int(2*len(df)/3)]
    third_df = df.iloc[int(2*len(df)/3):]
    numified_steps = first_df['Step'].apply(lambda x: int(x))
elif test_phase == 'idle':
    df['Step'] = df['Step'].apply(lambda x: "1 Idle")
    numified_steps = df['Step'].apply(lambda x: 1)
else:
    # for regression
    step2num = lambda x: int(x.split(' ')[0])
    numified_steps = df['Step'].apply(step2num)
    original_df = df.copy(deep=True)
    # new steps should go from <first_step> <resource> to the <last_step> so we can interpolate missing values
    first_step = df['Step'].iloc[0]
    last_step = df['Step'].iloc[-1]
    first_step_num, first_step_workload = first_step.split(' ')
    last_step_num, last_step_workload = last_step.split(' ')
    first_step_num = int(first_step_num)
    last_step_num = int(last_step_num)

plt.figure(figsize=(10, 6))
ax = plt.gca()

def plot_workloads(metric, type, numified_steps, df):
    type_num = type.split(' ')[0]
    colors = color_configs.get(type_num, color_configs['1'])

    color1 = colors['color1']
    color2 = colors['color2']
    color3 = colors['color3']

    if metric == 'api':
        plt.scatter(numified_steps, df['APIPerformance'], label='API Performance ' + type, marker='o', c=color1, edgecolors='black', s=100)
        plt.scatter(numified_steps, df['Webhook'], label='Webhook ' + type, marker='s', c=color2, edgecolors='black', s=100)
        plt.scatter(numified_steps, df['RequestLatency'], label='API Request Latency ' + type, marker='d', c=color3, edgecolors='black', s=100)

        coefficients_api_performance = np.polyfit(numified_steps, df['APIPerformance'], 1)
        p_api_performance = np.poly1d(coefficients_api_performance)
        plt.plot(numified_steps, p_api_performance(numified_steps), label='API Performance Regression ' + type + str(p_api_performance), linestyle='--', c=color1)

        coefficients_webhook = np.polyfit(numified_steps, df['Webhook'], 1)
        p_webhook = np.poly1d(coefficients_webhook)
        plt.plot(numified_steps, p_webhook(numified_steps), label='Webhook Regression ' + type + str(p_webhook), linestyle='--', c=color2)

        coefficients_request_latency = np.polyfit(numified_steps, df['RequestLatency'], 1)
        p_request_latency = np.poly1d(coefficients_request_latency)
        plt.plot(numified_steps, p_request_latency(numified_steps), label='Request Latency Regression ' + type + str(p_request_latency), linestyle='--', c=color3) 
    else:
        plt.scatter(numified_steps, df['Admission'], label='Admission ' + type, marker='o', c=color1, edgecolors='black', s=100)
        plt.scatter(numified_steps, df['Recommender'], label='Recommender ' + type, marker='s', c=color2, edgecolors='black', s=100)
        plt.scatter(numified_steps, df['Updater'], label='Updater ' + type, marker='d', c=color3, edgecolors='black', s=100)

        # ignore operator: doesn't have a linear relationship
        coefficients_admission = np.polyfit(numified_steps, df['Admission'], 1)
        p_admission = np.poly1d(coefficients_admission)
        plt.plot(numified_steps, p_admission(numified_steps), label='Admission eq ' + type + str(p_admission), linestyle='--', c=color1)

        coefficients_recommender = np.polyfit(numified_steps, df['Recommender'], 1)
        p_recommender = np.poly1d(coefficients_recommender)
        plt.plot(numified_steps, p_recommender(numified_steps), label='Recommender eq ' + type + str(p_recommender), linestyle='--', c=color2)

        coefficients_updater = np.polyfit(numified_steps, df['Updater'], 1)
        p_updater = np.poly1d(coefficients_updater)
        plt.plot(numified_steps, p_updater(numified_steps), label='Updater eq ' + type + str(p_updater), linestyle='--', c=color3)

# only show the y values that are originally in the CSV
if metric == 'cpu' or metric == 'memory':
    if test_phase == 'deployment-pods':
        plot_workloads('non-api', '1 pods', numified_steps, first_df)
        plot_workloads('non-api', '2 pods', numified_steps, second_df)
        plot_workloads('non-api', '4 pods', numified_steps, third_df)
    elif test_phase == 'deployment-containers':
        plot_workloads('non-api', '1 containers', numified_steps, first_df)
        plot_workloads('non-api', '2 containers', numified_steps, second_df)
        plot_workloads('non-api', '4 containers', numified_steps, third_df)
    else:
        plot_workloads('non-api', '', numified_steps, df)

    if metric == 'cpu':
        test_phase_title='CPU Usage Over REPLACE_ME (m) (interpolated)'
        plt.ylabel('CPU Usage (m)')
    elif metric == 'memory':
        test_phase_title='Memory Usage Over REPLACE_ME (MiB) (interpolated)'
        plt.ylabel('Memory Usage (MiB)')
elif metric == 'api':
    if test_phase == 'deployment-pods':
        plot_workloads('api', '1 pods', numified_steps, first_df)
        plot_workloads('api', '2 pods', numified_steps, second_df)
        plot_workloads('api', '4 pods', numified_steps, third_df)
    elif test_phase == 'deployment-containers':
        plot_workloads('api', '1 containers', numified_steps, first_df)
        plot_workloads('api', '2 containers', numified_steps, second_df)
        plot_workloads('api', '4 containers', numified_steps, third_df)
    else:
        plot_workloads('api', '', numified_steps, df)

    test_phase_title='API Performance Over REPLACE_ME (interpolated)'
    plt.ylabel('API Performance')

if test_phase == 'deployment':
    plt.xlabel('Number of Deployments')
    plt.title(test_phase_title.replace('REPLACE_ME', 'Deployments'))
elif test_phase == 'pod':
    plt.xlabel('Number of Pods')
    plt.title(test_phase_title.replace('REPLACE_ME', 'Pods'))
elif test_phase == 'deployment-pods':
    plt.xlabel('Number of Deployments')
    plt.title(test_phase_title.replace('REPLACE_ME', 'Deployments and Pods'))
elif test_phase == 'deployment-containers':
    plt.xlabel('Number of Deployments')
    plt.title(test_phase_title.replace('REPLACE_ME', 'Deployments and Containers'))
elif test_phase == 'idle':
    plt.xlabel('Idle after 20 minutes')
    plt.title('Idle Performance')
plt.legend()

plt.xticks(numified_steps, rotation=45)

plt.tight_layout()

plt.show()
